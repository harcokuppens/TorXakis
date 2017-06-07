{-
TorXakis - Model Based Testing
Copyright (c) 2015-2016 TNO and Radboud University
See license.txt
-}


module ModelDef
where

import qualified Data.Set as Set

import BehExprDefs
import ChanId

data  ModelDef       = ModelDef   [Set.Set ChanId] [Set.Set ChanId] [Set.Set ChanId] BExpr
     deriving (Eq,Ord,Read,Show)

-- ----------------------------------------------------------------------------------------- --
--
-- ----------------------------------------------------------------------------------------- --

