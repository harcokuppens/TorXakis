{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  TorXakis.TestSortContext
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
-- 
-- Maintainer  :  pierre.vandelaar@tno.nl (ESI)
-- Stability   :  experimental
-- Portability :  portable
--
-- Sort Context for Test: 
-- Additional functionality to ensure termination for QuickCheck
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module TorXakis.TestSortContext
(-- * Test Sort Context
  TestSortContext (..)
, MinimalTestSortContext(..)
)
where
import           Control.DeepSeq     (NFData)
import           Data.Data           (Data)
import qualified Data.HashMap        as Map
import           Data.Maybe          (catMaybes, fromMaybe)
import qualified Data.Text           as T
import           GHC.Generics        (Generic)

import           TorXakis.Error
import           TorXakis.Name
import           TorXakis.Sort



-- | A TestSortContext instance contains all definitions to work with sort and reference thereof for test purposes
class SortContext a => TestSortContext a where
    -- |  adt Size
    --   A size of complexity (indicated by an 'Int') is returned when the following constraint is satisfied:
    --
    --   * The context contains the 'ADTDef' reference.
    --
    --   Otherwise an error is return. The error reflects the violations of the formentioned constraint.
    adtSize :: a -> RefByName ADTDef -> Either MinError Int
    adtSize ctx r = case Map.lookup (SortADT r) (mapSortSize ctx) of
                        Just i  -> Right i
                        Nothing -> Left $ MinError (T.pack ("reference not contained in context " ++ show r))

    -- | get Sort to Size map
    mapSortSize :: a -> Map.Map Sort Int
    
    -- |  constructor Size
    --   A size of complexity (indicated by an 'Int') is returned when the following constraints are satisfied:
    --
    --   * The context contains the 'ADTDef' reference.
    --
    --   * The context contains the 'ConstructorDef' reference for the referred 'ADTDef'.
    --
    --   Otherwise an error is return. The error reflects the violations of any of the formentioned constraints.
    constructorSize :: a -> RefByName ADTDef -> RefByName ConstructorDef -> Either MinError Int
    constructorSize ctx r c = case Map.lookup r (mapAdtMapConstructorSize ctx) of
                                Nothing -> Left $ MinError (T.pack ("ADT reference not contained in context " ++ show r))
                                Just m -> case Map.lookup c m of
                                            Nothing -> Left $ MinError (T.pack ("component reference " ++ show c ++ " not contained in ADT " ++ show r))
                                            Just i -> Right i

    -- | get ConstructorDef to Size map
    mapConstructorDefSize :: a -> RefByName ADTDef -> Either MinError (Map.Map (RefByName ConstructorDef) Int)
    mapConstructorDefSize ctx r = case Map.lookup r (mapAdtMapConstructorSize ctx) of
                                        Nothing -> Left $ MinError (T.pack ("ADT reference not contained in context " ++ show r))
                                        Just m -> Right m

    -- | get map ADTDef to (map ConstructorDef to size)
    mapAdtMapConstructorSize :: a -> Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int)

-- | A minimal instance of 'TestSortContext'.
data MinimalTestSortContext = MinimalTestSortContext 
                                    { _adtDefs :: Map.Map (RefByName ADTDef) ADTDef
                                    , _mapSortSize :: Map.Map Sort Int
                                    , _mapAdtMapConstructorSize :: Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int)
                                    } deriving (Eq, Ord, Read, Show, Generic, NFData, Data)

instance SortContext MinimalTestSortContext where
    empty = MinimalTestSortContext Map.empty primitiveSortSize Map.empty
      where
        primitiveSortSize :: Map.Map Sort Int
        primitiveSortSize = Map.fromList [ (SortBool, 0)
                                         , (SortInt,0)
                                         , (SortChar, 0)
                                         , (SortString, 0)
                                         , (SortRegex, 0)
                                         ]

    adtDefs = _adtDefs

    addAdtDefs context as = case violationsAddAdtDefs context as of
                                Just e  -> Left e
                                Nothing -> let newAdtDefs = Map.union (_adtDefs context) (toMapByName as)
                                               newMapSortSize = addToMapSortSize (_mapSortSize context) as 
                                               newMapAdtMapConstructorSize = addToMapAdtMapConstructorSize (_mapAdtMapConstructorSize context) newMapSortSize as 
                                             in
                                                Right $ MinimalTestSortContext  newAdtDefs
                                                                                newMapSortSize
                                                                                newMapAdtMapConstructorSize
      where
            addToMapAdtMapConstructorSize :: Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int)
                                          -> Map.Map Sort Int
                                          -> [ADTDef]
                                          -> Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int)
            addToMapAdtMapConstructorSize cMap sMap =
                foldl addConstructorSizes cMap
              where
                addConstructorSizes :: Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int) 
                                    -> ADTDef 
                                    -> Map.Map (RefByName ADTDef) (Map.Map (RefByName ConstructorDef) Int)
                addConstructorSizes iMap adef =
                    let ra :: RefByName ADTDef
                        ra = RefByName (getName adef) in
                        if Map.member ra iMap 
                            then error ("Invariant violated: adding already contained ADTDef " ++ show adef)
                            else Map.insert ra (Map.fromList (map (\(rc,c) -> (rc, getConstructorSize sMap c) ) ((Map.toList . constructors . viewADTDef) adef) ) ) iMap

            addToMapSortSize :: Map.Map Sort Int -> [ADTDef] -> Map.Map Sort Int
            addToMapSortSize defined adefs =
                let newDefined = foldl addCurrent defined adefs
                    in if newDefined == defined 
                        then if any (`Map.notMember` newDefined) (map (SortADT . RefByName . getName) adefs)
                                then error ("Invariant violated: non constructable ADTDefs in " ++ show adefs)
                                else newDefined
                        else addToMapSortSize newDefined adefs
              where 
                addCurrent :: Map.Map Sort Int -> ADTDef -> Map.Map Sort Int
                addCurrent mp aDef = case getKnownAdtSize mp aDef of
                                        Nothing -> mp
                                        Just i  -> Map.insert (SortADT (RefByName (getName aDef))) i mp

                getKnownAdtSize :: Map.Map Sort Int -> ADTDef -> Maybe Int
                getKnownAdtSize mp adef =
                    case catMaybes knownConstructorSizes of
                        [] -> Nothing
                        cs -> Just $ 1 + minimum cs
                      where
                        knownConstructorSizes :: [Maybe Int]
                        knownConstructorSizes = map (getKnownConstructorSize mp) ( (Map.elems . constructors . viewADTDef) adef)

            getKnownConstructorSize :: Map.Map Sort Int -> ConstructorDef -> Maybe Int
            getKnownConstructorSize defined cdef =
                    foldl max 0 <$> sequence fieldSizes
                where
                    fieldSizes :: [Maybe Int]
                    fieldSizes = map ( (`Map.lookup` defined) . sort ) ( (fields . viewConstructorDef) cdef )

            getConstructorSize :: Map.Map Sort Int -> ConstructorDef -> Int
            getConstructorSize defined cdef = fromMaybe (error ("Invariant violated: unable to calculate size of ConstructorDef " ++ show cdef) )
                                                        (getKnownConstructorSize defined cdef)


instance TestSortContext MinimalTestSortContext where
    mapSortSize = _mapSortSize
    mapAdtMapConstructorSize = _mapAdtMapConstructorSize

instance PrettyPrint MinimalTestSortContext where
    prettyPrint = prettyPrintSortContext