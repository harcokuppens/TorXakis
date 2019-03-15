{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  FuncDef
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
-- 
-- Maintainer  :  pierre.vandelaar@tno.nl (Embedded Systems Innovation by TNO)
-- Stability   :  experimental
-- Portability :  portable
--
-- Function Definition
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module TorXakis.FuncDef
( FuncDef
, TorXakis.FuncDef.funcName
, paramDefs
, body
, mkFuncDef
)
where

import           Control.DeepSeq      (NFData)
import           Data.Data            (Data)
import qualified Data.Set             as Set
import qualified Data.Text            as T
import           GHC.Generics         (Generic)

import           TorXakis.ContextVar
import           TorXakis.Error
import           TorXakis.FuncSignature
import           TorXakis.FuncSignatureContext
import           TorXakis.FunctionName
import           TorXakis.PrettyPrint.TorXakis
import           TorXakis.Name
import           TorXakis.Sort
import           TorXakis.VarContext
import           TorXakis.Var
import           TorXakis.ValExpr.ValExpr

-- | Data structure to store the information of a Function Definition:
-- * A Name
-- * A list of variables
-- * A body (possibly using the variables)
data FuncDef = FuncDef { -- | The name of the function (of type 'TorXakis.Name')
                         funcName :: FunctionName
                         -- | The function parameter definitions
                       , paramDefs :: VarsDecl
                         -- | The body of the function
                       , body :: ValExpression
                       }
     deriving (Eq, Ord, Show, Read, Generic, NFData, Data)

toVarContext :: SortContext c => c -> [VarDef] -> ContextVar
toVarContext ctx vs =
    case addVars vs (fromSortContext ctx) of
        Left e      -> error ("toVarContext is unable to make new context" ++ show e)
        Right vctx  -> vctx

-- | constructor for FuncDef
mkFuncDef :: SortContext c => c -> FunctionName -> VarsDecl -> ValExpression -> Either Error FuncDef
mkFuncDef ctx n ps b | not (null undefinedSorts)                                = Left $ Error ("Variables have undefined sorts " ++ show undefinedSorts)
                     | not (Set.null undefinedVars)                             = Left $ Error ("Undefined variables used in body " ++ show undefinedVars)
                     | not (isReservedFunctionSignature ctx n argSorts retSort) = Left $ Error ("Function has reserved signature " ++ show n ++ " " ++ show argSorts ++ " " ++ show retSort)
                     | not (isPredefinedNonSolvableFuncSignature signature)     = Left $ Error ("Function has predefined signature " ++ show n ++ " " ++ show argSorts ++ " " ++ show retSort)
                     | otherwise                                                = Right $ FuncDef n ps b
    where
        vs :: [VarDef]
        vs = toList ps

        varContext :: ContextVar
        varContext = toVarContext ctx vs
        
        undefinedSorts :: Set.Set Sort
        undefinedSorts = Set.unions [usedSorts ctx ps, usedSorts varContext b] `Set.difference` Set.fromList (elemsSort ctx)

        undefinedVars :: Set.Set (RefByName VarDef)
        undefinedVars = freeVars b `Set.difference` Set.fromList (map (RefByName . name) vs)

        argSorts :: [Sort]
        argSorts = map (getSort ctx) vs

        retSort :: Sort
        retSort = getSort varContext b

        signature :: FuncSignature
        signature = case mkFuncSignature ctx n argSorts retSort of
                        Left e  -> error ("mkFuncDef is unable to create FuncSignature" ++ show e)
                        Right f -> f

instance SortContext c => HasFuncSignature c FuncDef
    where
        getFuncSignature ctx (FuncDef fn ps bd) =
            let vs = toList ps in
                case mkFuncSignature ctx fn (map (getSort ctx) vs) (getSort (toVarContext ctx vs) bd) of
                     Left e -> error ("getFuncSignature is unable to create FuncSignature" ++ show e)
                     Right x -> x

instance SortContext c => PrettyPrint c FuncDef where
    prettyPrint o c fd = 
        let vctx = toVarContext c (toList (paramDefs fd)) in
            TxsString ( T.concat [ T.pack "FUNCDEF "
                                 , TorXakis.FunctionName.toText (TorXakis.FuncDef.funcName fd)
                                 , separator o
                                 , indent (T.pack "   ") (TorXakis.PrettyPrint.TorXakis.toText (prettyPrint o c (paramDefs fd)))
                                 , T.pack " :: "
                                 , TorXakis.PrettyPrint.TorXakis.toText (prettyPrint o c (getSort vctx (body fd)))
                                 , separator o
                                 , T.pack "::="
                                 , separator o
                                 , indent (T.pack "   ") (TorXakis.PrettyPrint.TorXakis.toText (prettyPrint o vctx (body fd)))
                                 , separator o
                                 , T.pack "ENDDEF"
                                 ] )

-- ----------------------------------------------------------------------------------------- --
--
-- ----------------------------------------------------------------------------------------- --
