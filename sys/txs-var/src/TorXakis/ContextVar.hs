{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  VarContext
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
--
-- Maintainer  :  pierre.vandelaar@tno.nl (Embedded Systems Innovation by TNO)
-- Stability   :  experimental
-- Portability :  portable
--
-- Context for Variables.
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module TorXakis.ContextVar
( -- * Context Variable instance
  ContextVar
, fromSortContext
)
where
import           Control.DeepSeq        (NFData)
import           Data.Data              (Data)
import qualified Data.HashMap    as HashMap
import           GHC.Generics           (Generic)

import           TorXakis.Error
import           TorXakis.Name
import           TorXakis.Sort          ( SortReadContext(..)
                                        , SortContext(..)
                                        )
import           TorXakis.VarContext
import           TorXakis.VarDef

-- | An instance of 'TorXakis.VarContext'.
data ContextVar a = ContextVar { sortContext :: a
                                 -- variable definitions
                               , varDefs :: HashMap.Map (RefByName VarDef) VarDef
                               } deriving (Eq, Ord, Read, Show, Generic, NFData, Data)

-- | Create VarContext from SortContext
fromSortContext :: a -> ContextVar a
fromSortContext srt = ContextVar srt HashMap.empty

instance SortReadContext a => SortReadContext (ContextVar a) where
    memberSort   = memberSort . sortContext

    memberADT = memberADT . sortContext

    lookupADT = lookupADT . sortContext

    elemsADT  = elemsADT . sortContext

instance SortContext a => SortContext (ContextVar a) where
    empty = fromSortContext empty
    addADTs ctx as = case addADTs (sortContext ctx) as of
                          Left e     -> Left e
                          Right sctx -> Right $ ctx {sortContext = sctx}

instance SortReadContext a => VarReadContext (ContextVar a) where
    memberVar ctx v = HashMap.member v (varDefs ctx)

    lookupVar ctx v = HashMap.lookup v (varDefs ctx)

    elemsVar ctx    = HashMap.elems (varDefs ctx)

instance SortContext a => VarContext (ContextVar a) where
    addVars ctx vs
        | not $ null nuVarDefs               = Left $ Error ("Non unique variable definitions: " ++ show nuVarDefs)
        | not $ null undefinedSorts          = Left $ Error ("List of variable definitions with undefined sorts: " ++ show undefinedSorts)
        | otherwise                          = Right $ ctx {varDefs = HashMap.union (toMapByName vs) (varDefs ctx)}
      where
        nuVarDefs :: [VarDef]
        nuVarDefs = repeatedByName vs

        undefinedSorts :: [VarDef]
        undefinedSorts = filter (not . memberSort ctx . sort) vs
