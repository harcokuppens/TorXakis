{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}

-----------------------------------------------------------------------------
-- |
-- Module      :  TorXakis.ProblemSolver
-- Copyright   :  (c) 2015-2017 TNO and Radboud University
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Pierre van de Laar <pierre.vandelaar@tno.nl>
-- Stability   :  provisional
-- Portability :  portable
--
-- This module provides the ProblemSolver class.
-----------------------------------------------------------------------------
module TorXakis.ProblemSolver
( Solution (..)
, SolvableProblem (..)
, SolveProblem (..)
, KindOfProblem (..)
, ProblemSolver (..)
, assertSolution
, negateSolution
)
where

import           Control.Monad.IO.Class
import           Data.Either
import           Data.HashMap
import           Data.List

import           TorXakis.ContextValExpr
import           TorXakis.Name
import           TorXakis.Value
import           TorXakis.ValExpr
import           TorXakis.Var

-- ----------------------------------------------------------------------------------------- --
-- Problem solving definitions

-- | Is Problem Solvable? i.e. does a solution exist?
newtype SolvableProblem = SolvableProblem { -- | to Maybe Bool: `Nothing` to handle limitations of the problem solver.
                                            toMaybeBool :: Maybe Bool
                                          } deriving (Eq, Ord, Read, Show)

-- | Solution
-- TODO: rename to assignment and move to ValExpr (with the functions assertAssignment and negateAssignment)
newtype  Solution = Solution { -- | to Map from Variable Name and Value
                               toMap :: Map (RefByName VarDef) Value
                             } deriving (Eq, Ord, Read, Show)

-- | Solve Problem, i.e. give a solution
-- Include `UnableToSolve` to enable for limitation of the problem solver.
data  SolveProblem = Solved Solution
                   | Unsolvable
                   | UnableToSolve
     deriving (Eq, Ord, Read, Show)

-- | Kind of solution
data KindOfSolution = NoSolution
                    | UniqueSolution
                    | MultipleSolutions
     deriving (Eq, Ord, Read, Show)

-- | Kind of problem
newtype KindOfProblem = KindOfProblem { -- | to Maybe
                                        toMaybeKindOfSolution :: Maybe KindOfSolution
                                      } deriving (Eq, Ord, Read, Show)
-- | The Problem Solver class.
class MonadIO p => ProblemSolver p where
    -- | Info on Problem Solver
    info :: p String

    -- | Add ADTDefs
    -- precondition: `depth` == 0
    addADTs :: [ADTDef] -> p ()
    -- | Add Functions
    -- precondition: `depth` == 0
    addFunctions :: [FuncDef] -> p ()       -- TODO: rename to addFuncs like FuncContext?

    -- | depth of nested contexts
    -- postcondition: `depth` >= 0
    depth :: p Integer
    -- | push: add new nested context
    -- return new depth
    push :: p Integer
    -- | pop: remove deepest nested context
    -- precondition: `depth` > 0
    -- return new depth
    pop :: p Integer

    -- | Declare Variables to current nested context.
    -- precondition: `depth` > 0
    declareVariables :: [VarDef] -> p ()
    -- | add Assertions to current nested context.
    addAssertions :: [ValExpression] -> p()

    -- | is Problem Solvable?
    solvable :: p SolvableProblem

    -- | solve Problem, yet only return part of the solution.
    -- When a solution exists, only return the values associated with the provided variable references.
    -- precondition: All provided variable references point to a declared variable in the current problem.
    solvePartSolution :: [RefByName VarDef] -> p SolveProblem

    -- | solve Problem
    -- When the problem is solvable, a solution mapping all variables in the problem to a value is returned.
    solve :: p SolveProblem
    solve = do
                ctx <- toValExprContext
                solvePartSolution $ Data.List.map (RefByName . name) (elemsVar ctx)

    -- | What is the kind of problem?
    kindOfProblem :: p KindOfProblem
    kindOfProblem = do
        s <- solve
        case s of
            UnableToSolve -> return $ KindOfProblem Nothing
            Unsolvable    -> return $ KindOfProblem (Just NoSolution)
            Solved sol    -> do
                                ctx <- toValExprContext
                                case negateSolution ctx sol of
                                    Left e          -> error ("negateSolution unexpectedly failed with " ++ show e)
                                    Right assert    -> do
                                                            _ <- push
                                                            addAssertions [assert]
                                                            s' <- solvable
                                                            _ <- pop
                                                            case toMaybeBool s' of
                                                                Nothing    -> return $ KindOfProblem Nothing
                                                                Just False -> return $ KindOfProblem (Just UniqueSolution)
                                                                Just True  -> return $ KindOfProblem (Just MultipleSolutions)

    -- | conversion
    toValExprContext :: p ContextValExpr

-- | Boolean value expression that asserts the provided solution.
assertSolution :: VarContext c => c -> Solution -> Either Error ValExpression
assertSolution c sol = case partitionEithers [ mkVar c v >>= (\x -> mkConst c w >>= mkEqual c x)
                                             | (v,w) <- Data.HashMap.toList (toMap sol)
                                             ] of
                            ( [], vs ) -> Right vs
                            ( es, _ )  -> error ("unexpected errors in assertSolution " ++ intercalate "\n" (Prelude.map show es))
                        >>= mkAnd c

-- | Boolean value expression that negates the provided solution.
negateSolution :: VarContext c => c -> Solution -> Either Error ValExpression
negateSolution c sol = assertSolution c sol >>= mkNot c

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --