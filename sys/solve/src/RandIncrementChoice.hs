{-
TorXakis - Model Based Testing
Copyright (c) 2015-2016 TNO and Radboud University
See license.txt
-}
-- ----------------------------------------------------------------------------------------- --
module RandIncrementChoice
-- ----------------------------------------------------------------------------------------- --
--
--   Module RandIncrementChoice :  Randomization of SMT solutions - Solving by incrementally fixing one choice at a time
--
-- ----------------------------------------------------------------------------------------- --
-- export
( randValExprsSolveIncrementChoice  --  :: (Variable v) => [v] -> [ValExpr v] -> SMT (Satisfaction v)
)
where
-- ----------------------------------------------------------------------------------------- --
-- import
import System.IO
import System.Random
import System.Random.Shuffle
import Control.Monad.State

import qualified Data.Char as Char
import qualified Data.Map  as Map

import SMT
import SMTData
import SolveDefs
import StdTDefs
import TxsDefs

-- ----------------------------------------------------------------------------------------- --
-- give a random solution for constraint vexps with free variables vars


randValExprsSolveIncrementChoice :: (Variable v) => [v] -> [ValExpr v] -> SMT (SolveProblem v)
randValExprsSolveIncrementChoice freevars exprs  =
    -- if not all constraints are of type boolean: stop, otherwise solve the constraints
    if all ( (sortId_Bool == ) . sortOf ) exprs
    then do
        push
        addDeclarations freevars
        addAssertions exprs
        sat <- getSolvable
        sp <- case sat of 
                Sat     -> do
                            param_max_rand_depth_string <- getParam "param_max_rand_depth"
                            let param_max_rand_depth = read param_max_rand_depth_string
                            shuffledVars <- shuffleM freevars
                            randomSolve (zip shuffledVars (map (const param_max_rand_depth) [1::Integer .. ]) ) 0
                            sol <- getSolution freevars
                            return $ Solved sol
                Unsat   -> return Unsolvable
                Unknown -> return UnableToSolve
        pop
        return sp
    else do
        lift $ hPutStrLn stderr "TXS RandIncrementChoice randValExprsSolveIncrementChoice: Not all added constraints are Bool\n"
        return UnableToSolve


toRegexString :: Int -> String
toRegexString  45 = "\\-"
toRegexString  91 = "\\["
toRegexString  92 = "\\\\"
toRegexString  93 = "\\]"
toRegexString  94 = "\\^"
toRegexString   c = [Char.chr c]
        
-- precondition: SMT has returned sat        
randomSolve :: Variable v => [(v, Int)] -> Int -> SMT ()
randomSolve []        _     = return ()                                         -- empty list -> done
randomSolve ((_,0):_) _     = error "At maximum depth: should not be added"     -- todo: remove for performance gain!
randomSolve ((v,_):xs) i    | vsort v == sortId_Bool =
    do
        b <- lift randomIO
        c <- randomSolveVar v (choicesFunc v b)
        case c of
            Cbool x -> addAssertions [cstrEqual (cstrVar v) (cstrConst (Cbool x))]
            _       -> error "RandIncrementChoice: impossible constant - bool"
        sat <- getSolvable
        case sat of 
            Sat     -> randomSolve xs i
            _       -> error "Unexpected SMT issue - previous solution is no longer valid - Bool"
    where
        choicesFunc :: Variable v => v -> Bool -> Const -> [(Bool, ValExpr v)]
        choicesFunc v' b (Cbool b')  = let cond = b == b' in
                                         [ (cond,     cstrEqual (cstrVar v') (cstrConst (Cbool b)))
                                         , (not cond, cstrEqual (cstrVar v') (cstrConst (Cbool (not b)))) 
                                         ]
        choicesFunc _ _ _        = error "RandIncrementChoice: impossible choice - bool"

randomSolve ((v,_):xs) i    | vsort v == sortId_Int =
    do
        param_IncrementChoice_IntRange_string <- getParam "param_IncrementChoice_IntRange"
        let param_IncrementChoice_IntRange = read param_IncrementChoice_IntRange_string
        
        param_IncrementChoice_IntPower_string <- getParam "param_IncrementChoice_IntPower"
        let param_IncrementChoice_IntPower = read param_IncrementChoice_IntPower_string :: Integer
        
        b <- lift $ randomRIO (- param_IncrementChoice_IntRange, param_IncrementChoice_IntRange)
        let r = if b < 0 then - abs b ^ param_IncrementChoice_IntPower
                         else b ^ param_IncrementChoice_IntPower
        c <- randomSolveVar v (choicesFunc v r)
        case c of
            Cint x  -> addAssertions [cstrEqual (cstrVar v) (cstrConst (Cint x))]
            _       -> error "RandIncrementChoice: impossible constant - int"
        sat <- getSolvable
        case sat of 
            Sat     -> randomSolve xs i
            _       -> error "Unexpected SMT issue - previous solution is no longer valid - Int"
    where
        choicesFunc :: Variable v => v -> Integer -> Const -> [(Bool, ValExpr v)]
        choicesFunc v' r (Cint x)  = let cond = x < r in
                                     [ (cond,     cstrFunc funcId_ltInt [cstrVar v', cstrConst (Cint r)]) 
                                     , (not cond, cstrFunc funcId_geInt [cstrVar v', cstrConst (Cint r)]) 
                                     ]
        choicesFunc _ _ _         = error "RandIncrementChoice: impossible choice - int"

randomSolve ((v,-123):xs) i    | vsort v == sortId_String =                 -- abuse depth to encode char versus string
    do
        r <- lift $ randomRIO (0,127)
        s <- randomSolveVar v (choicesFunc v r)
        case s of
            Cstring [c] -> addAssertions [cstrEqual (cstrVar v) (cstrConst (Cstring [c]))]
            _           -> error "RandIncrementChoice: impossible constant - char"
        sat <- getSolvable
        case sat of 
            Sat     -> randomSolve xs i
            _       -> error "Unexpected SMT issue - previous solution is no longer valid - char"
    where
        choicesFunc :: Variable v => v -> Int -> Const -> [(Bool, ValExpr v)]
        choicesFunc v' r (Cstring [c]) = let cond = r <= Char.ord c && Char.ord c <= r+127 in
                                     [ (cond,     cstrFunc funcId_strinre [cstrVar v', cstrConst (Cregex ("[" ++ toRegexString r ++ "-" ++ toRegexString (r+127) ++ "]"))]) 
                                     , (not cond, case r of
                                                    0       -> cstrFunc funcId_strinre [cstrVar v', cstrConst (Cregex ("[" ++ toRegexString 128 ++ "-" ++ toRegexString 255 ++ "]"))]
                                                    1       -> cstrFunc funcId_strinre [cstrVar v', cstrConst (Cregex ("[" ++ toRegexString 129 ++ "-" ++ toRegexString 255 ++ toRegexString 0 ++ "]"))]
                                                    127     -> cstrFunc funcId_strinre [cstrVar v', cstrConst (Cregex ("[" ++ toRegexString 255 ++ toRegexString 0 ++ "-" ++ toRegexString 126 ++ "]"))]
                                                    _       -> cstrFunc funcId_strinre [cstrVar v', cstrConst (Cregex ("[" ++ toRegexString (r+128) ++ "-" ++ toRegexString 255 ++ 
                                                                                                                              toRegexString 0 ++ "-" ++ toRegexString (r-1) ++ "]"))]) 
                                     ]
        choicesFunc _ _ _         = error "RandIncrementChoice: impossible choice - char"
                                     
    
randomSolve ((v,d):xs) i    | vsort v == sortId_String =
    do
        r <- lift $ randomRIO (0,10)
        c <- randomSolveVar v (choicesFunc v r)
        case c of
            Cstring s   -> do
                                let l = length s
                                addAssertions [cstrEqual (cstrFunc funcId_lenString [cstrVar v]) (cstrConst (Cint (toInteger l)))]
                                if l > 0 && d > 1
                                then do
                                        let charVars = map (\iNew -> cstrVariable ("$$$t$" ++ show iNew) (10000000+iNew) sortId_String) [i .. i+l-1]
                                        addDeclarations charVars
                                        let exprs = map (\(vNew,p) -> cstrEqual (cstrVar vNew) (cstrFunc funcId_atString [cstrVar v, cstrConst (Cint p)])) (zip charVars [0..])
                                        addAssertions exprs
                                        shuffledVars <- shuffleM (xs ++ zip charVars (map (const (-123)) [1::Integer .. ]) )
                                        sat <- getSolvable
                                        case sat of 
                                            Sat     -> randomSolve shuffledVars (i+l)
                                            _       -> error "Unexpected SMT issue - previous solution is no longer valid - String - l > 0"
                                else do
                                        sat <- getSolvable
                                        case sat of 
                                            Sat     -> randomSolve xs i
                                            _       -> error "Unexpected SMT issue - previous solution is no longer valid - String - l == 0"
            _              -> error "RandIncrementChoice: impossible constant - string"
    where
        choicesFunc :: Variable v => v -> Int -> Const -> [(Bool, ValExpr v)]
        choicesFunc v' r (Cstring s) = let cond = length s < r in
                                     [ (cond,     cstrFunc funcId_ltInt [cstrFunc funcId_lenString [cstrVar v'], cstrConst (Cint (toInteger r))]) 
                                     , (not cond, cstrFunc funcId_geInt [cstrFunc funcId_lenString [cstrVar v'], cstrConst (Cint (toInteger r))]) 
                                     ]
        choicesFunc _ _ _         = error "RandIncrementChoice: impossible choice - string"
            
        
randomSolve ((v,d):xs) i = 
    do
        let sid = vsort v
        cstrs <- lookupConstructors sid
        case cstrs of
            []  -> error $ "Unexpected: no constructor for " ++ show v
            [(cid,cdef)] -> -- no choice -- one constructor
                    do
                        addIsConstructor v cdef
                        fieldVars <- addFields v i (cid,cdef)
                        sat <- getSolvable
                        case sat of 
                            Sat     -> do
                                            let l = length fieldVars
                                            if l > 0 
                                                then do                                    
                                                    shuffledVars <- shuffleM (xs ++ zip fieldVars (map (const d) [1::Integer .. ]) )
                                                    randomSolve shuffledVars (i+l)
                                                else
                                                    randomSolve xs i
                            _       -> error "Unexpected SMT issue - previous solution is no longer valid - ADT - 1"
            _   ->
                    do
                        shuffledCstrs <- shuffleM cstrs
                        let (partA, partB) = splitAt (div (length cstrs) 2) shuffledCstrs
                        c <- randomSolveVar v (choicesFunc v partA partB)
                        case c of
                            Cstr{cstrId = cid}  -> 
                                case Map.lookup cid (Map.fromList cstrs) of
                                    Just (cdef@CstrDef{})   -> 
                                        do
                                            addIsConstructor v cdef
                                            fieldVars <- if d > 1 then addFields v i (cid,cdef)
                                                                  else return []
                                            sat2 <- getSolvable
                                            case sat2 of 
                                                Sat     -> do
                                                                let l = length fieldVars
                                                                if l > 0 
                                                                    then do                                    
                                                                        shuffledVars <- shuffleM (xs ++ zip fieldVars (map (const (d-1)) [1::Integer .. ]) )
                                                                        randomSolve shuffledVars (i+l)
                                                                    else
                                                                        randomSolve xs i
                                                _       -> error "Unexpected SMT issue - previous solution is no longer valid - ADT - n"
                                    Nothing                 -> error "RandIncrementChoice: value not found - ADT - n"                        
                            _                   -> error "RandIncrementChoice: impossible constant - ADT - n"
    where
        choicesFunc :: Variable v => v -> [(CstrId, CstrDef)] -> [(CstrId, CstrDef)] -> Const -> [(Bool, ValExpr v)]
        choicesFunc v' partA partB Cstr{cstrId = cId} = 
            let cond = Map.member cId (Map.fromList partA) in
                                 [ (cond,     toOr (map (\(_,CstrDef isC _) -> cstrFunc isC [cstrVar v']) partA) )
                                 , (not cond, toOr (map (\(_,CstrDef isC _) -> cstrFunc isC [cstrVar v']) partB) )
                                 ]
        choicesFunc _ _ _ _        = error "RandIncrementChoice: impossible choice - string"

                        
                        
randomSolveVar :: (Variable v) => v -> (Const -> [(Bool, ValExpr v)]) -> SMT Const
randomSolveVar v choicesFunc = do
    sol <- getSolution [v]
    case Map.lookup v sol of
        Just c  -> do
                        let choices = choicesFunc c
                        shuffledChoices <- shuffleM choices
                        case head shuffledChoices of
                            (True , _)          -> return c
                            (False, assertion)  -> do
                                                        push
                                                        addAssertions [assertion]
                                                        sat <- getSolvable
                                                        case sat of 
                                                            Sat -> do
                                                                        sol2 <- getSolution [v]
                                                                        pop
                                                                        case Map.lookup v sol2 of
                                                                            Just c2 -> return c2
                                                                            _       -> error "RandIncrementChoice: value not found - randomSolveVar - 2"
                                                                        
                                                            _   -> do
                                                                        pop
                                                                        return c
        _       -> error "RandIncrementChoice: value not found - randomSolveVar"

-- lookup a constructor given its sort and constructor name
lookupConstructors :: SortId -> SMT [(CstrId, CstrDef)]
lookupConstructors sid  =  do
     tdefs <- gets txsDefs
     return [(cstrid, cdef) | (cstrid@(CstrId _ _ _ sid'), cdef) <- Map.toList (cstrDefs tdefs), sid == sid']
     
toOr :: (Variable v) => [ValExpr v] -> ValExpr v
toOr [] = cstrConst (Cbool False)
toOr [x] = x
toOr (x:xs) = cstrFunc funcId_or [x, toOr xs]

addIsConstructor :: (Variable v) => v -> CstrDef -> SMT ()
addIsConstructor v (CstrDef isC _) = addAssertions [cstrFunc isC [cstrVar v]]
    
addFields :: (Variable v) => v -> Int -> (CstrId, CstrDef) -> SMT [v]
addFields v i (CstrId { cstrargs = args' }, CstrDef _ fs) = do
    let fieldVars = map (\(iNew,sNew) -> cstrVariable ("$$$t$" ++ show iNew) (10000000+iNew) sNew) (zip [i .. ] args')
    addDeclarations fieldVars
    let exprs = map (\(fieldSelector, fieldVar) -> cstrEqual (cstrVar fieldVar) (cstrFunc fieldSelector [cstrVar v])) (zip fs fieldVars)
    addAssertions exprs
    return fieldVars
-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --
