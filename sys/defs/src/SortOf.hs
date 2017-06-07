{-
TorXakis - Model Based Testing
Copyright (c) 2015-2016 TNO and Radboud University
See license.txt
-}

-- ----------------------------------------------------------------------------------------- --
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
module SortOf

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- SortOf for TxsDefs
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --

where

import qualified Data.Set  as Set
import qualified Data.Map  as Map
import Data.Maybe (fromMaybe)

import BehExprDefs
import ConnectionDefs
import ConstDefs
import CstrId
import FuncId
import SortId
import VarId
import ValExprDefs
import Variable

-- ----------------------------------------------------------------------------------------- --
-- value expression, etc. :  sortOf -------------------------------------------------------- --

-- ----------------------------------------------------------------------------------------- --
-- standard sorts

sortId_Bool :: SortId
sortId_Bool   = SortId "Bool"   101

sortId_Int :: SortId
sortId_Int    = SortId "Int"    102

sortId_String :: SortId
sortId_String = SortId "String" 104

sortId_Regex :: SortId
sortId_Regex  = SortId "Regex"  105

class SortOf s
  where
    sortOf :: s -> SortId


instance SortOf ChanOffer
  where
    sortOf (Quest (VarId _nm _uid vs))          =  vs
    sortOf (Exclam vexp)                        =  sortOf vexp

sortIdError :: SortId
sortIdError = SortId "_Error" (-1)

instance (Variable v) => SortOf (ValExpr v)
  where
    sortOf vexp = let s = sortOf' vexp in
                      if s == sortIdError
                        then sortId_String
                        else s
                        

sortOf' :: (Variable v) => ValExpr v -> SortId
sortOf' (view -> Vfunc (FuncId _nm _uid _fa fs) _vexps) =  fs
sortOf' (view -> Vfunc _ _)                             = error "sortOf': Unexpected Ident with Vfunc"
sortOf' (view -> Vcstr (CstrId _nm _uid _ca cs) _vexps) =  cs
sortOf' (view -> Vcstr _ _)                             = error "sortOf': Unexpected Ident with Vcstr"
sortOf' (view -> Vconst con)                            =  sortOf con
sortOf' (view -> Vvar v)                                =  vsort v
sortOf' (view -> Vite _cond vexp1 vexp2)                =  -- if the LHS is an error (Verror), we want to yield the type of the RHS which might be no error
                                                             let sort' = sortOf' vexp1 in 
                                                             if sort' == sortIdError
                                                               then sortOf' vexp2
                                                               else sort'
sortOf' (view -> Venv _ve vexp)                         =  sortOf' vexp
sortOf' (view -> Vequal _ _)                            =  sortId_Bool
sortOf' (view -> Vpredef _kd (FuncId _nm _uid _fa fs) _vexps)  =  fs
sortOf' (view -> Vpredef{})                             = error "sortOf': Unexpected Ident with Vpredef"
sortOf' (view -> Verror _str)                           =  sortIdError


instance SortOf Const
  where
    sortOf (Cbool _b)                               = sortId_Bool
    sortOf (Cint _i)                                = sortId_Int 
    sortOf (Cstring _s)                             = sortId_String
    sortOf (Cstr (CstrId _nm _uid _ca cs) _)        = cs
    sortOf _                                        = error "Unexpect SortOf - Const"


instance SortOf VarId
  where
    sortOf (VarId _nm _unid srt)                    = srt

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --

