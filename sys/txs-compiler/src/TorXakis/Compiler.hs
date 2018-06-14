{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
module TorXakis.Compiler where

import           Control.Arrow                      (first, second, (&&&),
                                                     (|||))
import           Control.Lens                       (over, (^.), (^..))
import           Control.Monad.Error.Class          (liftEither)
import           Control.Monad.State                (evalStateT, get)
import           Data.Data.Lens                     (uniplate)
import           Data.Map.Strict                    (Map)
import qualified Data.Map.Strict                    as Map
import           Data.Maybe                         (catMaybes, fromMaybe)
import qualified Data.Set                           as Set
import           Data.Text                          (Text)
import           Data.Tuple                         (swap)

import           ChanId                             (ChanId)
import           CstrId                             (CstrId)
import           FuncDef                            (FuncDef (FuncDef))
import           FuncId                             (FuncId (FuncId), name)
import qualified FuncId
import           FuncTable                          (FuncTable, Handler,
                                                     Signature (Signature),
                                                     toMap)
import           Id                                 (Id (Id), _id)
import           Sigs                               (Sigs, chan, func, pro,
                                                     sort, uniqueCombine)
import qualified Sigs                               (empty)
import           SortId                             (SortId, sortIdBool,
                                                     sortIdInt, sortIdRegex,
                                                     sortIdString)
import           StdTDefs                           (stdFuncTable, stdTDefs)
import           TxsDefs                            (ProcDef, ProcId, TxsDefs,
                                                     cnectDefs, fromList,
                                                     funcDefs, mapperDefs,
                                                     modelDefs, procDefs,
                                                     purpDefs, union)
import qualified TxsDefs                            (empty)
import           ValExpr                            (ValExpr,
                                                     ValExprView (Vfunc, Vite),
                                                     cstrITE, cstrVar, view)
import           VarId                              (VarId, varsort)
import qualified VarId

import           TorXakis.Compiler.Data
import           TorXakis.Compiler.Defs.ChanId
import           TorXakis.Compiler.Defs.ProcDef
import           TorXakis.Compiler.Defs.Sigs
import           TorXakis.Compiler.Defs.TxsDefs
import           TorXakis.Compiler.Error            (Error)
import           TorXakis.Compiler.Maps
import           TorXakis.Compiler.Maps.DefinesAMap
import           TorXakis.Compiler.MapsTo
import           TorXakis.Compiler.Simplifiable
import           TorXakis.Compiler.ValExpr.Common
import           TorXakis.Compiler.ValExpr.CstrId
import           TorXakis.Compiler.ValExpr.ExpDecl
import           TorXakis.Compiler.ValExpr.FuncDef
import           TorXakis.Compiler.ValExpr.FuncId
import           TorXakis.Compiler.ValExpr.SortId
import           TorXakis.Compiler.ValExpr.ValExpr
import           TorXakis.Compiler.ValExpr.VarId

import           TorXakis.Compiler.Data.ProcDecl
import           TorXakis.Compiler.Defs.FuncTable
import           TorXakis.Compiler.Maps.VarRef
import           TorXakis.Parser
import           TorXakis.Parser.BExpDecl
import           TorXakis.Parser.Data
import           TorXakis.Parser.ValExprDecl

-- | Compile a string into a TorXakis model.
--
compileFile :: FilePath -> IO (Either Error (Id, TxsDefs, Sigs VarId))
compileFile fp = do
    ePd <- parseFile fp
    case ePd of
        Left err -> return . Left $ err
        Right pd -> return $
            evalStateT (runCompiler . compileParsedDefs $ pd) newState


compileUnsafe :: CompilerM a -> a
compileUnsafe cmp = throwOnError $
    evalStateT (runCompiler cmp) newState

-- | Legacy compile function, used to comply with the old interface. It should
-- be deprecated in favor of @compile@.
compileLegacy :: String -> (Id, TxsDefs, Sigs VarId)
compileLegacy str =
    case parseString "" str of
        Left err -> error $ show err
        Right pd ->
            compileUnsafe (compileParsedDefs pd)

throwOnError :: Either Error a -> a
throwOnError = throwOnLeft ||| id
    where throwOnLeft = error . show

compileParsedDefs :: ParsedDefs -> CompilerM (Id, TxsDefs, Sigs VarId)
compileParsedDefs pd = do
    sIds <- compileToSortIds pd
    cstrIds <- compileToCstrId sIds (pd ^. adts)

    stdFuncIds <- Map.fromList <$> getStdFuncIds
    cstrFuncIds <- Map.fromList <$> adtsToFuncIds sIds (pd ^. adts)
    fIds <- Map.fromList <$> funcDeclsToFuncIds sIds (allFuncs pd)
    let
        allFids = stdFuncIds `Map.union` cstrFuncIds `Map.union` fIds
        lfDefs = compileToFuncLocs allFids

    decls <- compileToDecls lfDefs pd
    -- Infer the types of all variable declarations.
    let emptyVdMap = Map.empty :: Map (Loc VarDeclE) SortId
    -- We pass to 'inferTypes' an empty map from 'Loc VarDeclE' to 'SortId'
    -- since no variables can be declared at the top level.
    let allFSigs = funcIdAsSignature <$> allFids
    vdSortMap <- inferTypes (sIds :& decls :& allFSigs :& emptyVdMap) (allFuncs pd)
    -- Construct the variable declarations to @VarId@'s lookup table.
    vIds <- generateVarIds vdSortMap (allFuncs pd)

    --
    -- UNDER REFACTOR!
    --

    adtsFt <- adtsToFuncTable (sIds :& cstrIds) (pd ^. adts)
    stdSHs <- fLocToSignatureHandlers stdFuncIds stdFuncTable
    adtsSHs <- fLocToSignatureHandlers cstrFuncIds adtsFt
    -- TODO: The @FuncDef@s are only required by the @toTxsDefs@, so it makes sense to
    -- split @funcDeclsToFuncDefs2@ into:
    --
    -- - 'funcDeclsToSignatureHandlers'
    -- - 'funcDeclsToFuncDefs' (to be used at @toTxsDefs@)
    fSHs <- Map.fromList <$> traverse (funcDeclToSH allFids) (allFuncs pd)

    fdefs <- funcDeclsToFuncDefs2 (vIds :& allFids :& decls)
                                  (stdSHs `Map.union` adtsSHs `Map.union` fSHs)
                                  (allFuncs pd)
    let fdefsSHs = innerSigHandlerMap (fIds :& fdefs)
        allFSHs = stdSHs `Map.union` adtsSHs `Map.union` fdefsSHs

    --
    -- UNDER REFACTOR!
    --
    pdefs <- compileToProcDefs (sIds :& cstrIds :& allFids :& allFSHs :& decls) pd
    chIds <- getMap sIds (pd ^. chdecls) :: CompilerM (Map (Loc ChanDeclE) ChanId)
    let mm = sIds :& pdefs :& cstrIds :& allFids :& fdefs
    sigs    <- toSigs (mm :& chIds) pd
    -- We need the map from channel names to the locations in which these
    -- channels are declared, because the model definitions rely on channels
    -- declared outside its scope.
    chNames <-  getMap () (pd ^. chdecls) :: CompilerM (Map Text (Loc ChanDeclE))
    txsDefs <- toTxsDefs (func sigs) (mm :& decls :& vIds :& vdSortMap :& chNames :& chIds :& allFSHs) pd
    St i    <- get
    return (Id i, txsDefs, sigs)

toTxsDefs :: ( MapsTo Text        SortId mm
             , MapsTo (Loc CstrE) CstrId mm
             , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
             , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
             , MapsTo (Loc FuncDeclE) FuncId mm
             , MapsTo FuncId FuncDefInfo mm
             , MapsTo ProcId ProcDef mm
             , MapsTo Text (Loc ChanDeclE) mm
             , MapsTo (Loc ChanDeclE) ChanId mm
             , MapsTo (Loc VarDeclE) VarId mm
             , MapsTo (Loc VarDeclE) SortId mm
             , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
             , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
             , In (ProcId, ()) (Contents mm) ~ 'False )
          => FuncTable VarId -> mm -> ParsedDefs -> CompilerM TxsDefs
toTxsDefs ft mm pd = do
    ads <- adtsToTxsDefs mm (pd ^. adts)
    -- Get the function id's of all the constants.
    cfIds <- traverse (mm .@) (pd ^.. consts . traverse . loc')
    let
        fdiMap :: Map FuncId FuncDefInfo
        fdiMap = innerMap mm
        fdefMap :: Map FuncId (FuncDef VarId)
        fdefMap = funcDef <$> fdiMap
        -- TODO: we have to remove the constants to comply with what TorXakis generates :/
        funcDefsNoConsts = Map.withoutKeys fdefMap (Set.fromList cfIds)
        -- TODO: we have to simplify to comply with what TorXakis generates.
        fn = idefsNames mm ++ fmap name cfIds
        fds = TxsDefs.empty {
            funcDefs = simplify ft fn funcDefsNoConsts
            }
        pds = TxsDefs.empty {
            procDefs = simplify ft fn (innerMap mm)
            }
    -- TODO: why not have these functions return a TxsDef data directly.
    -- Simplify this boilerplate!
    mDefMap <- modelDeclsToTxsDefs mm (pd ^. models)
    let mds = TxsDefs.empty { modelDefs = simplify ft fn mDefMap }
    uDefMap <- purpDeclsToTxsDefs mm (pd ^. purps)
    let uds = TxsDefs.empty { purpDefs = simplify ft fn uDefMap }
    cDefMap <- cnectDeclsToTxsDefs mm (pd ^. cnects)
    let cds = TxsDefs.empty { cnectDefs = simplify ft fn cDefMap }
    rDefMap <- mapperDeclsToTxsDefs mm (pd ^. mappers)
    let rds = TxsDefs.empty { mapperDefs = simplify ft fn rDefMap }
    return $ ads
        `union` fds
        `union` pds
        `union` fromList stdTDefs
        `union` mds
        `union` uds
        `union` cds
        `union` rds

toSigs :: ( MapsTo Text        SortId mm
          , MapsTo (Loc CstrE) CstrId mm
          , MapsTo (Loc FuncDeclE) FuncId mm
          , MapsTo FuncId FuncDefInfo mm
          , MapsTo ProcId ProcDef mm
          , MapsTo (Loc ChanDeclE) ChanId mm)
       => mm -> ParsedDefs -> CompilerM (Sigs VarId)
toSigs mm pd = do
    let ts   = sortsToSigs (innerMap mm)
    as  <- adtDeclsToSigs mm (pd ^. adts)
    fs  <- funDeclsToSigs mm (pd ^. funcs)
    cs  <- funDeclsToSigs mm (pd ^. consts)
    let pidMap :: Map ProcId ProcDef
        pidMap = innerMap mm
        ss = Sigs.empty { func = stdFuncTable
                        , chan = values @(Loc ChanDeclE) mm
                        , pro  = Map.keys pidMap
                        }
    return $ ts `uniqueCombine` as
        `uniqueCombine` fs
        `uniqueCombine` cs
        `uniqueCombine` ss

funcDefInfoNamesMap :: [Loc FuncDeclE] -> Map Text [Loc FuncDeclE]
funcDefInfoNamesMap fdis =
    groupByName $ catMaybes $ asPair <$> fdis
    where
      asPair :: Loc FuncDeclE -> Maybe (Text, Loc FuncDeclE)
      asPair fdi = (, fdi) <$> fdiName fdi
      groupByName :: [(Text, Loc FuncDeclE)] -> Map Text [Loc FuncDeclE]
      groupByName = Map.fromListWith (++) . fmap (second pure)

-- | Get a dictionary from sort names to their @SortId@. The sorts returned
-- include all the sorts defined by a 'TYPEDEF' (in the parsed definitions),
-- and the predefined sorts ('Bool', 'Int', 'Regex', 'String').
compileToSortIds :: ParsedDefs -> CompilerM (Map Text SortId)
compileToSortIds pd = do
    -- Construct the @SortId@'s lookup table.
    sMap <- compileToSortId (pd ^. adts)
    let pdsMap = Map.fromList [ ("Bool", sortIdBool)
                              , ("Int", sortIdInt)
                              , ("Regex", sortIdRegex)
                              , ("String", sortIdString)
                              ]
    return $ Map.union pdsMap sMap

-- | Get all the functions in the parsed definitions.
allFuncs :: ParsedDefs -> [FuncDecl]
allFuncs pd = pd ^. funcs ++ pd ^. consts

-- | Get a dictionary from the function names to the locations in which these
-- functions are defined.
--
compileToFuncLocs :: Map (Loc FuncDeclE) FuncId -> Map Text [Loc FuncDeclE]
compileToFuncLocs fIds = Map.fromListWith (++) $
    fmap mkPair (Map.toList fIds)
    where
      mkPair :: (Loc FuncDeclE, FuncId) -> (Text, [Loc FuncDeclE])
      mkPair (fdi, fId) = (name fId, [fdi])

-- | Get a dictionary from variable references to the possible location in
-- which these variables are declared. Due to overloading a syntactic reference
-- to a variable can refer to a variable, or multiple functions.
compileToDecls :: Map Text [Loc FuncDeclE]
               -> ParsedDefs
               -> CompilerM (Map (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]))
compileToDecls lfDefs pd = do
    let eVdMap = Map.empty :: Map Text (Loc VarDeclE)
    fRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (allFuncs pd)
    pRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. procs)
    sRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. stauts)
    mRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. models)
    uRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. purps)
    cRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. cnects)
    rRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. mappers)
    return $ fRtoDs `Map.union` pRtoDs `Map.union` sRtoDs `Map.union` mRtoDs
            `Map.union` uRtoDs `Map.union` cRtoDs `Map.union` rRtoDs

-- | Generate the map from process id's definitions to process definitions.
compileToProcDefs :: ( MapsTo Text SortId mm
                     , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
                     , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
                     , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
                     , In (Loc ChanDeclE, ChanId) (Contents mm) ~ 'False
                     , In (Loc VarDeclE, VarId) (Contents mm) ~ 'False
                     , In (Text, ChanId) (Contents mm) ~ 'False
                     , In (Loc ProcDeclE, ProcInfo) (Contents mm) ~ 'False
                     , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
                     , In (ProcId, ()) (Contents mm) ~ 'False
                     , In (Loc VarDeclE, SortId) (Contents mm) ~ 'False)
                  => mm -> ParsedDefs -> CompilerM (Map ProcId ProcDef)
compileToProcDefs mm pd = do
    pmsP <- getMap mm (pd ^. procs)  :: CompilerM (Map (Loc ProcDeclE) ProcInfo)
    pmsS <- getMap mm (pd ^. stauts) :: CompilerM (Map (Loc ProcDeclE) ProcInfo)
    let pms = pmsP `Map.union` pmsS -- TODO: we might consider detecting for duplicated process here.
    procPDefMap  <- procDeclsToProcDefMap (pms :& mm) (pd ^. procs)
    stautPDefMap <- stautDeclsToProcDefMap (pms :& mm) (pd ^. stauts)
    return $ procPDefMap `Map.union` stautPDefMap

-- * External parsing functions

-- | Compiler for value definitions
--
-- name valdefsParser   ExNeValueDefs     -- valdefsParser   :: [Token]
--
-- Originally:
--
-- > SIGS VARENV UNID -> ( Int, VEnv )
--
-- Where
--
-- > SIGS   ~~ (Sigs VarId)
-- > VARENV ~~ [VarId]  WARNING!!!!! This thing is empty when used at the server, so we might not need it.
-- > UNID   ~~ Int
valdefsParser :: Sigs VarId
              -> [VarId]
              -> Int
              -> String
              -> CompilerM (Int, Map VarId (ValExpr VarId))
valdefsParser sIds fDefs unid str = do undefined
    -- ls <- liftEither $ parse 0 "" str letVarDeclsP
    -- setUnid unid
--     let
--         allFIds = Map.keys fDefs
--         -- We cannot refer to a variable previously declared
--         lsVDs = Map.empty :: Map Text (Loc VarDeclE)
--         lsFDs = mkFuncDecls allFIds
--         lsFIds = mkFuncIds allFIds
--         mm =  sIds
--            :& fDefs
--            :& lsFDs
--            :& lsFIds
--     lsVRs  <- Map.fromList <$>
--         mapRefToDecls (lsVDs :& lsFDs) (varDeclExp <$> ls)
--     let
--         -- We don't have any external variables we can use.
--         lsEVSIds = Map.empty :: Map (Loc VarDeclE) SortId
--         lsEVVIds = Map.empty :: Map (Loc VarDeclE) VarId
--         mm' = lsVRs :& lsEVSIds :& lsEVVIds :& mm
--     lVSIds <- liftEither $ letInferTypes mm' Map.empty ls
--     lVIds  <- mkVarIds (lVSIds <.+> mm') ls
    -- vEnv   <- liftEither $
    --     parValDeclToMap2 (lVSIds <.+> (lVIds <.++> mm')) ls
--     unid'  <- getUnid
--     return (unid', vEnv)

mkFuncDecls :: [FuncId] -> Map Text [Loc FuncDeclE]
mkFuncDecls fs = Map.fromListWith (++) $ zip (FuncId.name <$> fs)
                                             (pure . fIdToLoc <$> fs)

mkFuncIds :: [FuncId] -> Map (Loc FuncDeclE) FuncId
mkFuncIds fs = Map.fromList $ zip (fIdToLoc <$> fs) fs

-- TODO: place this in the appropriate module.
-- PROBLEM! The Sigs do not contain a FuncId!
-- sigsToFuncDefs :: Sigs -> Map FuncId (FuncDef VarId)
-- sigsToFuncDefs = undefined
--
-- TODO: think about renaming this to something like 'compileVExpr'
vexprParser :: Sigs VarId
            -> [VarId]
            -> Int
            -> String                        -- ^ String to parse.
            -> CompilerM (Int, ValExpr VarId)
vexprParser sigs vids unid str = do
    eDecl <- liftEither $ parse 0 "" str valExpP
    setUnid unid
--     let
--         allFIds = Map.keys fDefs
--         fIds :: Map (Loc FuncDeclE) FuncId
--         fIds = mkFuncIds allFIds
--         eFDs :: Map Text [Loc FuncDeclE]
--         eFDs = mkFuncDecls allFIds
--         eVDs :: Map Text (Loc VarDeclE)
--         eVDs = Map.fromList $ zip (VarId.name <$> allVars) (varIdToLoc <$> allVars)
--         -- | SortIds of the pre-existing variables
--         vSIdsPre :: Map (Loc VarDeclE) SortId
--         vSIdsPre = Map.fromList $ zip (varIdToLoc <$> allVars) (varsort <$> allVars)
--     vRefs <- Map.fromList <$>
--         mapRefToDecls (eVDs :& eFDs) eDecl
--     let
--         mm =  sIds     -- MapsTo Text SortId mm
--            :& fIds     -- MapsTo (Loc FuncDeclE) FuncId mm
--            :& vRefs    -- MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
--            :& vSIdsPre -- MapsTo (Loc VarDeclE) SortId
--             -- TODO: if we change @HasTypedVars@ to @DefinesAMap@ then we don't
--             -- need the dummy maps below.
--            :& (Map.empty :: Map ProcId ())
--            :& (Map.empty :: Map (Loc ChanDeclE) ChanId)
--            :& (Map.empty :: Map (Loc ChanRefE) (Loc ChanDeclE))
--     vSIds <- Map.fromList <$> inferVarTypes mm eDecl
--     vIds  <- Map.fromList <$> mkVarIds (vSIds <.+> mm) eDecl
--     let
--         mm' =  (vSIds <.+> mm)
--             :& fDefs -- MapsTo FuncId (FuncDef VarId) mm
--             :& vIds  -- MapsTo (Loc VarDeclE) VarId mm

    -- vSIds <- Map.fromList <$> inferVarTypes mm eDecl

    let
        tSids :: Map Text SortId
        tSids = sort sigs
        vsids :: Map (Loc VarDeclE) SortId
        vsids = undefined
        fsigs :: Map (Loc FuncDeclE) Signature
        fsigs = undefined
        vdecls :: Map (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE])
        vdecls = undefined
        mm = tSids :& vsids :& fsigs :& vdecls

    eSid  <- liftEither $ inferExpTypes mm eDecl >>= getUniqueElement

    let
        fshs :: Map (Loc FuncDeclE) (Signature, Handler VarId)
        fshs = undefined
        vvids :: Map (Loc VarDeclE) VarId
        vvids = undefined
        mm' =  vdecls
            :& vvids
            :& fshs

    vrvds <- liftEither $ varDefsFromExp mm' eDecl
    vExp  <- liftEither $ expDeclToValExpr vrvds eSid eDecl
    unid' <- getUnid
    return (unid', vExp)

fIdToLoc :: FuncId -> Loc FuncDeclE
fIdToLoc fId = PredefLoc (FuncId.name fId) (_id . FuncId.unid $ fId)

varIdToLoc :: VarId -> Loc VarDeclE
varIdToLoc vId = PredefLoc (VarId.name vId) (_id . VarId.unid $ vId)
