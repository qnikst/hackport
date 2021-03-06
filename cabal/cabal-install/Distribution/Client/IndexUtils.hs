-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.IndexUtils
-- Copyright   :  (c) Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  duncan@community.haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Extra utils related to the package indexes.
-----------------------------------------------------------------------------
module Distribution.Client.IndexUtils (
  getInstalledPackages,
  getSourcePackages,

  readPackageIndexFile,
  parseRepoIndex,
  ) where

import qualified Distribution.Client.Tar as Tar
import Distribution.Client.Types

import Distribution.Package
         ( PackageId, PackageIdentifier(..), PackageName(..)
         , Package(..), packageVersion
         , Dependency(Dependency), InstalledPackageId(..) )
import Distribution.Client.PackageIndex (PackageIndex)
import qualified Distribution.Client.PackageIndex as PackageIndex
import qualified Distribution.Simple.PackageIndex as InstalledPackageIndex
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
import Distribution.PackageDescription
         ( GenericPackageDescription )
import Distribution.PackageDescription.Parse
         ( parsePackageDescription )
import Distribution.Simple.Compiler
         ( Compiler, PackageDBStack )
import Distribution.Simple.Program
         ( ProgramConfiguration )
import qualified Distribution.Simple.Configure as Configure
         ( getInstalledPackages )
import Distribution.ParseUtils
         ( ParseResult(..) )
import Distribution.Version
         ( Version(Version), intersectVersionRanges )
import Distribution.Text
         ( simpleParse )
import Distribution.Verbosity
         ( Verbosity, lessVerbose )
import Distribution.Simple.Utils
         ( warn, info, fromUTF8, equating )

import Data.Maybe  (catMaybes, fromMaybe)
import Data.List   (isPrefixOf, groupBy)
import Data.Monoid (Monoid(..))
import qualified Data.Map as Map
import Control.Monad (MonadPlus(mplus), when)
import Control.Exception (evaluate)
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Lazy.Char8 as BS.Char8
import Data.ByteString.Lazy (ByteString)
import Distribution.Client.GZipUtils (maybeDecompress)
import System.FilePath ((</>), takeExtension, splitDirectories, normalise)
import System.FilePath.Posix as FilePath.Posix
         ( takeFileName )
import System.IO.Error (isDoesNotExistError)
import System.Directory
         ( getModificationTime )
import System.Time
         ( getClockTime, diffClockTimes, normalizeTimeDiff, TimeDiff(tdDay) )

getInstalledPackages :: Verbosity -> Compiler
                     -> PackageDBStack -> ProgramConfiguration
                     -> IO (PackageIndex InstalledPackage)
getInstalledPackages verbosity comp packageDbs conf =
    fmap convert (Configure.getInstalledPackages verbosity'
                                                 comp packageDbs conf)
  where
    --FIXME: make getInstalledPackages use sensible verbosity in the first place
    verbosity'  = lessVerbose verbosity

    convert :: InstalledPackageIndex.PackageIndex -> PackageIndex InstalledPackage
    convert index = PackageIndex.fromList
      -- There can be multiple installed instances of each package version,
      -- like when the same package is installed in the global & user dbs.
      -- InstalledPackageIndex.allPackagesByName gives us the installed
      -- packages with the most preferred instances first, so by picking the
      -- first we should get the user one. This is almost but not quite the
      -- same as what ghc does.
      [ InstalledPackage ipkg (sourceDeps index ipkg)
      | ipkgs <- InstalledPackageIndex.allPackagesByName index
      , (ipkg:_) <- groupBy (equating packageVersion) ipkgs ]

    -- The InstalledPackageInfo only lists dependencies by the
    -- InstalledPackageId, which means we do not directly know the corresponding
    -- source dependency. The only way to find out is to lookup the
    -- InstalledPackageId to get the InstalledPackageInfo and look at its
    -- source PackageId. But if the package is broken because it depends on
    -- other packages that do not exist then we have a problem we cannot find
    -- the original source package id. Instead we make up a bogus package id.
    -- This should have the same effect since it should be a dependency on a
    -- non-existant package.
    sourceDeps index ipkg =
      [ maybe (brokenPackageId depid) packageId mdep
      | let depids = InstalledPackageInfo.depends ipkg
            getpkg = InstalledPackageIndex.lookupInstalledPackageId index
      , (depid, mdep) <- zip depids (map getpkg depids) ]

    brokenPackageId (InstalledPackageId str) =
      PackageIdentifier (PackageName (str ++ "-broken")) (Version [] [])

-- | Read a repository index from disk, from the local files specified by
-- a list of 'Repo's.
--
-- All the 'SourcePackage's are marked as having come from the appropriate
-- 'Repo'.
--
-- This is a higher level wrapper used internally in cabal-install.
--
getSourcePackages :: Verbosity -> [Repo] -> IO SourcePackageDb
getSourcePackages verbosity [] = do
  warn verbosity $ "No remote package servers have been specified. Usually "
                ++ "you would have one specified in the config file."
  return SourcePackageDb {
    packageIndex       = mempty,
    packagePreferences = mempty
  }
getSourcePackages verbosity repos = do
  info verbosity "Reading available packages..."
  pkgss <- mapM (readRepoIndex verbosity) repos
  let (pkgs, prefs) = mconcat pkgss
      prefs' = Map.fromListWith intersectVersionRanges
                 [ (name, range) | Dependency name range <- prefs ]
  _ <- evaluate pkgs
  _ <- evaluate prefs'
  return SourcePackageDb {
    packageIndex       = pkgs,
    packagePreferences = prefs'
  }

-- | Read a repository index from disk, from the local file specified by
-- the 'Repo'.
--
-- All the 'SourcePackage's are marked as having come from the given 'Repo'.
--
-- This is a higher level wrapper used internally in cabal-install.
--
readRepoIndex :: Verbosity -> Repo
              -> IO (PackageIndex SourcePackage, [Dependency])
readRepoIndex verbosity repo = handleNotFound $ do
  let indexFile = repoLocalDir repo </> "00-index.tar"
  (pkgs, prefs) <- either fail return
                 . foldlTarball extract ([], [])
               =<< BS.readFile indexFile

  pkgIndex <- evaluate $ PackageIndex.fromList
    [ SourcePackage {
        packageInfoId      = pkgid,
        packageDescription = pkg,
        packageSource      = RepoTarballPackage repo pkgid Nothing
      }
    | (pkgid, pkg) <- pkgs]

  warnIfIndexIsOld indexFile
  return (pkgIndex, prefs)

  where
    extract (pkgs, prefs) entry = fromMaybe (pkgs, prefs) $
              (do pkg <- extractPkg entry; return (pkg:pkgs, prefs))
      `mplus` (do prefs' <- extractPrefs entry; return (pkgs, prefs'++prefs))

    extractPrefs :: Tar.Entry -> Maybe [Dependency]
    extractPrefs entry = case Tar.entryContent entry of
    {-
     -- get rid of hackage's preferred-versions
     -- I'd like to have bleeding-edge packages in system and I don't fear of
     -- broken packages with improper depends
      Tar.NormalFile content _
         | takeFileName (Tar.entryPath entry) == "preferred-versions"
        -> Just . parsePreferredVersions
         . BS.Char8.unpack $ content
    -}
      _ -> Nothing

    handleNotFound action = catch action $ \e -> if isDoesNotExistError e
      then do
        case repoKind repo of
          Left  remoteRepo -> warn verbosity $
               "The package list for '" ++ remoteRepoName remoteRepo
            ++ "' does not exist. Run 'hackport update' to download it."
          Right _localRepo -> warn verbosity $
               "The package list for the local repo '" ++ repoLocalDir repo
            ++ "' is missing. The repo is invalid."
        return mempty
      else ioError e

    isOldThreshold = 15 --days
    warnIfIndexIsOld indexFile = do
      indexTime   <- getModificationTime indexFile
      currentTime <- getClockTime
      let diff = normalizeTimeDiff (diffClockTimes currentTime indexTime)
      when (tdDay diff >= isOldThreshold) $ case repoKind repo of
        Left  remoteRepo -> warn verbosity $
             "The package list for '" ++ remoteRepoName remoteRepo
          ++ "' is " ++ show (tdDay diff)  ++ " days old.\nRun "
          ++ "'hackport update' to get the latest list of available packages."
        Right _localRepo -> return ()

parsePreferredVersions :: String -> [Dependency]
parsePreferredVersions = catMaybes
                       . map simpleParse
                       . filter (not . isPrefixOf "--")
                       . lines

-- | Read a compressed \"00-index.tar.gz\" file into a 'PackageIndex'.
--
-- This is supposed to be an \"all in one\" way to easily get at the info in
-- the hackage package index.
--
-- It takes a function to map a 'GenericPackageDescription' into any more
-- specific instance of 'Package' that you might want to use. In the simple
-- case you can just use @\_ p -> p@ here.
--
readPackageIndexFile :: Package pkg
                     => (PackageId -> GenericPackageDescription -> pkg)
                     -> FilePath -> IO (PackageIndex pkg)
readPackageIndexFile mkPkg indexFile = do
  pkgs <- either fail return
        . parseRepoIndex
        . maybeDecompress
      =<< BS.readFile indexFile
  
  evaluate $ PackageIndex.fromList
   [ mkPkg pkgid pkg | (pkgid, pkg) <- pkgs]

-- | Parse an uncompressed \"00-index.tar\" repository index file represented
-- as a 'ByteString'.
--
parseRepoIndex :: ByteString
               -> Either String [(PackageId, GenericPackageDescription)]
parseRepoIndex = foldlTarball (\pkgs -> maybe pkgs (:pkgs) . extractPkg) []

extractPkg :: Tar.Entry -> Maybe (PackageId, GenericPackageDescription)
extractPkg entry = case Tar.entryContent entry of
  Tar.NormalFile content _
     | takeExtension fileName == ".cabal"
    -> case splitDirectories (normalise fileName) of
        [pkgname,vers,_] -> case simpleParse vers of
          Just ver -> Just (pkgid, descr)
            where
              pkgid  = PackageIdentifier (PackageName pkgname) ver
              parsed = parsePackageDescription . fromUTF8 . BS.Char8.unpack
                                               $ content
              descr  = case parsed of
                ParseOk _ d -> d
                _           -> error $ "Couldn't read cabal file "
                                    ++ show fileName
          _ -> Nothing
        _ -> Nothing
  _ -> Nothing
  where
    fileName = Tar.entryPath entry

foldlTarball :: (a -> Tar.Entry -> a) -> a
             -> ByteString -> Either String a
foldlTarball f z = either Left (Right . foldl f z) . check [] . Tar.read
  where
    check _  (Tar.Fail err)  = Left  err
    check ok Tar.Done        = Right ok
    check ok (Tar.Next e es) = check (e:ok) es
