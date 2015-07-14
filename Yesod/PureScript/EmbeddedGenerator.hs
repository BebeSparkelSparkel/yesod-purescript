{-# LANGUAGE QuasiQuotes, TemplateHaskell, DataKinds, OverloadedStrings, TupleSections #-}
-- | Embed compiled purescript into the 'EmbeddedStatic' subsite.
--
-- This module provides an alternative way of embedding purescript code into a yesod application,
-- and is orthogonal to the support in "Yesod.PureScript".
--
-- To use this module, you should place all your purescript code into a single directory as files
-- with a @purs@ extension.  Next, you should use <http://bower.io/ bower> to manage purescript
-- dependencies.  You can then give your directory and all dependency directories to the generators
-- below.  (At the moment, you must list each dependency explicitly.  A future improvement is to
-- parse bower.json to find dependencies.)
--
-- For example, after installing bootstrap, purescript-either, and purescript-maybe using bower and
-- then adding purescript code to a directory called @myPurescriptDir@, you could use code such as the
-- following to create a static subsite.
--
-- >import Yesod.EmbeddedStatic
-- >import Yesod.PureScript.EmbeddedGenerator
-- >
-- >#ifdef DEVELOPMENT
-- >#define DEV_BOOL True
-- >#else
-- >#define DEV_BOOL False
-- >#endif
-- >mkEmbeddedStatic DEV_BOOL "myStatic" [
-- > 
-- >   purescript "js/mypurescript.js" uglifyJs ["MyPurescriptModule"]
-- >     [ "myPurescriptDir"
-- >     , "bower_components/purescript-either/src"
-- >     , "bower_components/purescript-maybe/src"
-- >     ]
-- > 
-- >  , embedFileAt "css/bootstrap.min.css" "bower_components/bootstrap/dist/boostrap.min.css"
-- >  , embedDirAt "fonts" "bower_components/bootstrap/dist/fonts"
-- >]
--
-- The result is that a variable `js_mypurescript_js` of type @Route EmbeddedStatic@ will be created
-- that when accessed will contain the javascript generated by the purescript compiler.  Assuming
-- @StaticR@ is your route to the embdedded static subsite, you can then reference these routes
-- using:
--
-- >someHandler :: Handler Html
-- >someHandler = defaultLayout $ do
-- >    addStylesheet $ StaticR css_bootstrap_min_css
-- >    addScript $ StaticR js_mypurescript_js
-- >    ...
--
module Yesod.PureScript.EmbeddedGenerator(
    purescript
  , defaultPsGeneratorOptions
  , PsGeneratorOptions(..)
  , PsModuleRoots(..)
) where

import Control.Monad (forM, when)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Writer (WriterT, runWriterT)
import Data.Default (def)
import Data.IORef
import Data.Maybe (catMaybes)
import Language.Haskell.TH.Syntax (Lift(..), liftString)
import System.FilePath ((</>))
import System.FilePath.Glob (glob)
import System.IO (hPutStrLn, stderr)
import Yesod.EmbeddedStatic
import Yesod.EmbeddedStatic.Types

import qualified Language.PureScript as P
import qualified Language.PureScript.Bundle as B
import qualified Language.PureScript.CoreFn as CF
import qualified Language.PureScript.CodeGen.JS as J
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Map as M

-- | Specify PureScript modules for the roots for dead code eliminiation
data PsModuleRoots = AllSourceModules
                        -- ^ All modules located in the 'psSourceDirectory' will be used as roots
                   | SpecifiedModules [String]
                        -- ^ The specified module names will be used as roots

instance Lift PsModuleRoots where
    lift AllSourceModules = [| AllSourceModules |]
    lift (SpecifiedModules mods) = [| SpecifiedModules $(lift mods) |]

-- | The options to the generator.
data PsGeneratorOptions = PsGeneratorOptions {
    psSourceDirectory :: FilePath
        -- ^ The source directory containing PureScript modules.  All files recursively with a @purs@ extension
        -- will be loaded as PureScript code, and all files recursively with a @js@ extension will
        -- be loaded as foreign javascript.
  , psDependencySrcGlobs :: [String]
        -- ^ A list of globs (input to 'glob') for dependency PureScript modules.
  , psDependencyForeignGlobs :: [String]
        -- ^ A list of globs (input to 'glob') for dependency foreign javascript.
  , psDeadCodeElim :: PsModuleRoots
        -- ^ The module roots to use for dead code eliminiation.  All identifiers reachable from
        -- these modules will be kept.
  , psProductionMinimizer :: BL.ByteString -> IO BL.ByteString
        -- ^ Javascript minifier such as 'uglifyJs' to use when compiling for production.
        --   This is not used when compiling for development.
  , psDevBuildDirectory :: FilePath
        -- ^ Directory used for caching the compiler output during development mode.  The
        -- directory will be created if it does not yet exist.  This directory can be
        -- removed/cleaned at any time as long as a build is not in progress.
}

instance Lift PsGeneratorOptions where
    lift opts = [| PsGeneratorOptions $(liftString $ psSourceDirectory opts)
                                      $(lift $ psDependencySrcGlobs opts)
                                      $(lift $ psDependencyForeignGlobs opts)
                                      $(lift $ psDeadCodeElim opts)
                                      return -- the lift instance is used only for development mode, where the minimizer is not used
                                      $(liftString $ psDevBuildDirectory opts)
                |]

-- | Default options for the generator.
--
--   * All of the PureScript code and foreign JS you develop should go into a directory
--   @purescript@.
--
--   * The dependencies are loaded from @bower_components/purescript-*/src/@.  Thus if you list
--   all your dependencies in @bower.json@, this generator will automatically pick them all up.
--
--   * 'AllSourceModules' is used for dead code elimination, which means all modules located in the
--   @purescript@ directory are used as roots for dead code elimination.  That is, all code
--   reachable from a module from the @purescript@ directory is kept, and all other code from the
--   dependencies is thrown away.
--
--   * No production minimizer is configured.
--
--   * The dev build directory is @.yesod-purescript-build@
defaultPsGeneratorOptions :: PsGeneratorOptions
defaultPsGeneratorOptions = PsGeneratorOptions
  { psSourceDirectory = "purescript"
  , psDependencySrcGlobs = ["bower_components/purescript-*/src/**/*.purs"]
  , psDependencyForeignGlobs = ["bower_components/purescript-*/src/**/*.js"]
  , psDeadCodeElim = AllSourceModules
  , psProductionMinimizer = return
  , psDevBuildDirectory = ".yesod-purescript-build"
  }

-- | Compile a PureScript project to a single javascript file.
--
-- When executing in development mode, the directory 'psDevBuildDirectory' is used to cache compiler
-- output. Every time a HTTP request for the given 'Location' occurs, the generator re-runs the
-- equivalent of @psc-make@. This recompiles any changed modules (detected by the file modification
-- time) and then bundles and serves the new javascript.  This allows you to change the PureScript
-- code or even add new PureScript modules, and a single refresh in the browser will recompile and
-- serve the new javascript without having to recompile/restart the Yesod server.
--
-- When compiling for production, the PureScript compiler will be executed to compile all PureScript
-- code and its dependencies.  The resulting javascript is then minimized, compressed, and embdedded
-- directly into the binary generated by GHC.  Thus you can distribute your compiled Yesod server
-- without having to distribute any PureScript code or its dependencies.  (This also means any
-- changes to the PureScript code requires a re-compile of the Haskell module containing the
-- call to 'purescript').
--
-- All generated javascript code will be available under the global @PS@ variable. Thus from julius
-- inside a yesod handler, you can access exports from modules via something like
-- @[julius|PS.modulename.someexport("Hello, World")|]@.  There will not be any call to a main
-- function; you can call the main function yourself from julius inside your handler.
purescript :: Location -> PsGeneratorOptions -> Generator
purescript loc opts = do
    return [def
      { ebHaskellName = Just $ pathToName loc
      , ebLocation = loc
      , ebMimeType = "application/javascript"
      , ebProductionContent = compileAndBundle loc opts ModeProduction >>= psProductionMinimizer opts
      , ebDevelReload = [| compileAndBundle $(liftString loc) $(lift opts) ModeDevelopment |]
      }]

data MakeMode = ModeDevelopment | ModeProduction
    deriving (Show, Eq)

type ParseOutput = ([(Either P.RebuildPolicy FilePath, P.Module)], M.Map P.ModuleName (FilePath, P.ForeignJS))
type CompilerOutput = [(B.ModuleIdentifier, String)]

-- | Helper function to parse the purescript modules
parse :: [(FilePath, String)] -> [(FilePath, String)] -> WriterT P.MultipleErrors (Either P.MultipleErrors) ParseOutput
parse files foreign =
    (,) <$> P.parseModulesFromFiles (either (const "") id) (map (\(fp,str) -> (Right fp, str)) files)
        <*> P.parseForeignModulesFromFiles foreign

-- | Compile and bundle the purescript
compileAndBundle :: Location -> PsGeneratorOptions -> MakeMode -> IO BL.ByteString
compileAndBundle loc opts mode = do
    hPutStrLn stderr $ "Compiling " ++ loc

    srcNames <- glob (psSourceDirectory opts </> "**/*.purs")
    depNames <- concat <$> mapM glob (psDependencySrcGlobs opts)
    foreignNames <- concat <$> mapM glob
        ((psSourceDirectory opts </> "**/*.js") : psDependencyForeignGlobs opts)
    psFiles <- mapM (\f -> (f,) <$> readFile f) $ srcNames ++ depNames
    foreignFiles <- mapM (\f -> (f,) <$> readFile f) foreignNames

    case runWriterT (parse psFiles foreignFiles) of
        Left err -> do
            hPutStrLn stderr $ P.prettyPrintMultipleErrors False err
            case mode of
                ModeProduction -> error "Error parsing purescript"
                ModeDevelopment -> return $ TL.encodeUtf8 $ TL.pack $ P.prettyPrintMultipleErrors False err
        Right (parseOutput, warnings) -> do
            when (P.nonEmpty warnings) $
                hPutStrLn stderr $ P.prettyPrintMultipleWarnings False warnings

            case mode of
                ModeDevelopment -> do
                    compileOutput <- compileDevel opts parseOutput
                    bundleOutput <- either (return . Left) (bundle opts srcNames parseOutput) compileOutput
                    case bundleOutput of
                        Left err -> return err
                        Right js -> return js

                ModeProduction -> do
                    compileOutput <- compileProd parseOutput
                    bundleOutput <- bundle opts srcNames parseOutput compileOutput
                    case bundleOutput of
                        Left _err -> error "Error while bundling javascript"
                        Right js -> return js

-- | Compile for development mode, using the disk-based make mode.
compileDevel :: PsGeneratorOptions -> ParseOutput -> IO (Either BL.ByteString CompilerOutput)
compileDevel opts (ms, foreigns) = do
    let filePathMap = M.fromList $ map (\(fp, P.Module _ mn _ _) -> (mn, fp)) ms

        actions = P.buildMakeActions (psDevBuildDirectory opts) filePathMap foreigns False
        compileOpts = P.defaultOptions { P.optionsNoOptimizations = True
                                       , P.optionsVerboseErrors = True
                                       }
    e <- P.runMake compileOpts $ P.make actions ms

    case e of
        Left err -> do
            hPutStrLn stderr $ P.prettyPrintMultipleErrors False err
            return $ Left $ TL.encodeUtf8 $ TL.pack $ P.prettyPrintMultipleErrors False err
        Right (_, warnings') -> do
            when (P.nonEmpty warnings') $
                hPutStrLn stderr $ P.prettyPrintMultipleWarnings False warnings'

            indexJs <- forM ms $ \(_, P.Module _ mn _ _) -> do
                idx <- readFile $ psDevBuildDirectory opts </> P.runModuleName mn </> "index.js"
                return (B.ModuleIdentifier (P.runModuleName mn) B.Regular, idx)

            return $ Right indexJs


-- | In-memory cache of purescript compiler output
data GeneratedCode = GeneratedCode {
    genIndexJs :: M.Map P.ModuleName String
  , genExterns :: M.Map P.ModuleName String
}

-- | Make actions that compile in memory
inMemoryMakeActions :: M.Map P.ModuleName (FilePath, P.ForeignJS) -> IORef GeneratedCode -> P.MakeActions P.Make
inMemoryMakeActions foreigns genCodeRef = P.MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
    where
        getInputTimestamp _ = return $ Left P.RebuildAlways
        getOutputTimestamp _ = return $ Nothing
        progress _ = return ()
        readExterns mn = liftIO $ do
            genCode <- readIORef genCodeRef
            case M.lookup mn (genExterns genCode) of
                Just js -> return ("<extern for " ++ P.runModuleName mn ++ ">", js)
                Nothing -> error $ "Unable to find externs for " ++ P.runModuleName mn

        codegen :: CF.Module CF.Ann -> P.Environment -> P.SupplyVar -> P.Externs -> P.Make ()
        codegen m _ nextVar exts = do
            let mn = CF.moduleName m
            foreignInclude <- case mn `M.lookup` foreigns of
              Just _ -> return $ Just $ J.JSApp (J.JSVar "require") [J.JSStringLiteral "./foreign"]
              Nothing -> return Nothing
            pjs <- P.evalSupplyT nextVar $ P.prettyPrintJS <$> J.moduleToJs m foreignInclude

            liftIO $ atomicModifyIORef' genCodeRef $ \genCode2 ->
                let newIndex = M.insert mn pjs $ genIndexJs genCode2
                    newExtern = M.insert mn exts $ genExterns genCode2
                 in (GeneratedCode newIndex newExtern, ())

-- | Compile for production
compileProd :: ParseOutput -> IO CompilerOutput
compileProd (ms, foreigns) = do
    genRef <- newIORef $ GeneratedCode M.empty M.empty
    let makeActions = inMemoryMakeActions foreigns genRef
    e <- P.runMake P.defaultOptions $ P.make makeActions ms
    case e of
        Left err -> do
            hPutStrLn stderr $ P.prettyPrintMultipleErrors False err
            error "Error compiling purescript"
        Right (_, warnings') -> do
            when (P.nonEmpty warnings') $
                hPutStrLn stderr $ P.prettyPrintMultipleWarnings False warnings'
            genCode <- readIORef genRef
            return [(B.ModuleIdentifier (P.runModuleName mn) B.Regular, js) | (mn, js) <- M.toList $ genIndexJs genCode ]

-- | Bundle the generated javascript
bundle :: PsGeneratorOptions -> [String] -> ParseOutput -> CompilerOutput -> IO (Either BL.ByteString BL.ByteString)
bundle opts srcNames (ms, foreigns) indexJs = do
    let checkSrcMod (Left _, _) = Nothing
        checkSrcMod (Right fp, P.Module _ mn _ _)
            | fp `elem` srcNames = Just mn
            | otherwise = Nothing
        srcModNames = catMaybes $ map checkSrcMod ms

        roots = case psDeadCodeElim opts of
                    AllSourceModules -> [ B.ModuleIdentifier (P.runModuleName mn) B.Regular | mn <- srcModNames]
                    SpecifiedModules mods -> [ B.ModuleIdentifier mn B.Regular | mn <- mods]

    let foreignBundleInput = [(B.ModuleIdentifier (P.runModuleName mn) B.Foreign, js) | (mn, (_, js)) <- M.toList foreigns ]
    
    case B.bundle (indexJs ++ foreignBundleInput) roots Nothing "PS" of
        Left err -> do
            hPutStrLn stderr $ unlines $ B.printErrorMessage err
            return $ Left $ TL.encodeUtf8 $ TL.pack $ unlines $ B.printErrorMessage err
        Right r -> return $ Right $ TL.encodeUtf8 $ TL.pack r
