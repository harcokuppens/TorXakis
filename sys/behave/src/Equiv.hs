{-
TorXakis - Model Based Testing
Copyright (c) 2015-2016 TNO and Radboud University
See license.txt
-}

{-# LANGUAGE FlexibleInstances #-}
-- ----------------------------------------------------------------------------------------- --

module Equiv

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- Equivalence on BTree's
--
-- ----------------------------------------------------------------------------------------- --
-- export

( Equiv (..)
, elemMby       -- elemM  :: (Monad m) => (a -> a -> m Bool) -> a -> [a] -> m Bool
, nubMby        -- nubMby :: (Monad m) => (a -> a -> m Bool) -> [a] -> m [a]
)

-- ----------------------------------------------------------------------------------------- --
-- import

where

import System.IO
import Control.Monad.State

import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Set  as Set
import qualified Data.Map  as Map

import TxsDefs
import StdTDefs
import TxsEnv
import CTree


-- import FreeVar
-- import Eval


-- ----------------------------------------------------------------------------------------- --
-- Equiv : equivalence


class (Eq e) => Equiv e
  where

    (~=~) :: e -> e -> IOE Bool
    (~/~) :: e -> e -> IOE Bool

    x ~=~ y  =  do  { return $ x == y }
    x ~/~ y  =  do  { eq <- x ~=~ y ;  return $ not eq }


instance (Equiv t) => Equiv [t]
  where
    []     ~=~ []      =  do  { return $ True }
    []     ~=~ (y:ys)  =  do  { return $ False }
    (x:xs) ~=~ []      =  do  { return $ False }
    (x:xs) ~=~ (y:ys)  =  do  { eq_hd <- x  ~=~ y
                              ; eq_tl <- xs ~=~ ys
                              ; return $ eq_hd && eq_tl
                              }


instance (Ord t,Equiv t) => Equiv (Set.Set t)
  where
    xs ~=~ ys  =  do
         xs' <- return $ Set.toList xs
         ys' <- return $ Set.toList ys
         xs_sub_ys <- sequence [ elemMby (~=~) x ys' | x <- xs' ]
         ys_sub_xs <- sequence [ elemMby (~=~) y xs' | y <- ys' ]
         return $ (and xs_sub_ys) && (and ys_sub_xs)


-- ----------------------------------------------------------------------------------------- --
-- Equiv :  BTree

{-  overlapping instances

instance Equiv BTree
  where
    btree1 ~=~ btree2  =  do
         (Set.fromList btree1) ~=~ (Set.fromList btree2)

-}


-- ----------------------------------------------------------------------------------------- --
-- Equiv :  BBranch


instance Equiv BBranch
  where

    (BTpref offs1 hvars1 preds1 next1) ~=~ (BTpref offs2 hvars2 preds2 next2)  =  do
         eq_offs  <- return $  offs1 == offs2
         eq_hvars <- return $ hvars1 == hvars2
         eq_preds <- return $ preds1 == preds2
         eq_next  <- next1 ~=~ next2
         return $ eq_offs && eq_hvars && eq_preds && eq_next

    (BTtau btree1) ~=~ (BTtau btree2)  =  do
         btree1 ~=~ btree2

    _ ~=~ _  =  do
         return $ False
       

-- ----------------------------------------------------------------------------------------- --
-- Equiv :  INode


instance Equiv INode
  where

    (BNbexpr (wenv1, ivenv1) bexp1) ~=~ (BNbexpr (wenv2, ivenv2) bexp2)  =  do
         eq_wenv  <- return $ wenv1  == wenv2
         eq_ivenv <- return $ ivenv1 == ivenv2
         eq_bexp  <- bexp1 ~=~ bexp2
         return $ eq_wenv && eq_ivenv && eq_bexp

    (BNparallel chids1 inodes1) ~=~ (BNparallel chids2 inodes2)  =  do
         eq_chids  <- return $ (Set.fromList chids1) == (Set.fromList chids2)
         eq_inodes <- inodes1 ~=~ inodes2
         return $ eq_chids && eq_inodes

    (BNenable inode11 choffs1 inode12) ~=~ (BNenable inode21 choffs2 inode22)  =  do
         eq_inode1 <- inode11 ~=~ inode21
         eq_choffs <- return $ (Set.fromList choffs1) == (Set.fromList choffs2)
         eq_inode2 <- inode12 ~=~ inode22
         return $ eq_inode1 && eq_choffs && eq_inode2 

    (BNdisable inode11 inode12) ~=~ (BNdisable inode21 inode22)  =  do
         eq_inode1 <- inode11 ~=~ inode21
         eq_inode2 <- inode12 ~=~ inode22
         return $ eq_inode1 && eq_inode2 

    (BNinterrupt inode11 inode12) ~=~ (BNinterrupt inode21 inode22)  =  do
         eq_inode1 <- inode11 ~=~ inode21
         eq_inode2 <- inode12 ~=~ inode22
         return $ eq_inode1 && eq_inode2 

    (BNhide chids1 inode1) ~=~ (BNhide chids2 inode2)  =  do
         eq_chids <- return $ (Set.fromList chids1) == (Set.fromList chids2)
         eq_inode <- inode1 ~=~ inode2
         return $ eq_chids && eq_inode

    _ ~=~ _  =  do
         return $ False


-- ----------------------------------------------------------------------------------------- --
-- Equiv :  ValExpr

{-

instance (VarId v) => Equiv (ValExpr v)
  where
    vexp1 ~=~ vexp2  =  if sortOf vexp1 == Bool && sortOf vexp2 == Bool
                             then if vexp1 == vexp2
                                then True
                                else  solvevexp1 => vexp2
                                      case sol of
                            nosolution: solve vexp2 => vexp1
                                   case sol of
                                  noslution ->< treu
                                    _ -> False
 
-}


-- ----------------------------------------------------------------------------------------- --
-- Equiv :  BExpr


instance Equiv BExpr
  where

    (Stop) ~=~ (Stop)  =  do
         return $ True

    (ActionPref (ActOffer offs1 cnrs1) bexp1) ~=~ (ActionPref (ActOffer offs2 cnrs2) bexp2) = do
         eq_offs <- return $ offs1 == offs2
         eq_cnrs <- return $ (Set.fromList cnrs1) == (Set.fromList cnrs2)
         eq_bexp <- bexp1 ~=~ bexp2
         return $ eq_offs && eq_cnrs && eq_bexp

    (Guard cnrs1 bexp1) ~=~ (Guard cnrs2 bexp2)  =  do
         eq_cnrs <- return $ (Set.fromList cnrs1) == (Set.fromList cnrs2)
         eq_bexp <- bexp1 ~=~ bexp2
         return $ eq_cnrs && eq_bexp

    (Choice bexps1) ~=~ (Choice bexps2)  =  do
         eq_bexps <- (Set.fromList bexps1) ~=~ (Set.fromList bexps2)
         return $ eq_bexps

    (Parallel chids1 bexps1) ~=~ (Parallel chids2 bexps2)  =  do
         eq_chids <- return $ (Set.fromList chids1) == (Set.fromList chids2)
         eq_bexps <- bexps1 ~=~ bexps2
         return $ eq_chids && eq_bexps

    (Enable bexp11 choffs1 bexp12) ~=~ (Enable bexp21 choffs2 bexp22)  =  do
         eq_bexp1  <- bexp11 ~=~ bexp21
         eq_choffs <- return $ (Set.fromList choffs1) == (Set.fromList choffs2)
         eq_bexp2  <- bexp12 ~=~ bexp22
         return $ eq_bexp1 && eq_choffs && eq_bexp2

    (Disable bexp11 bexp12) ~=~ (Disable bexp21 bexp22)  =  do
         eq_bexp1  <- bexp11 ~=~ bexp21
         eq_bexp2  <- bexp12 ~=~ bexp22
         return $ eq_bexp1 && eq_bexp2

    (Interrupt bexp11 bexp12) ~=~ (Interrupt bexp21 bexp22)  =  do
         eq_bexp1  <- bexp11 ~=~ bexp21
         eq_bexp2  <- bexp12 ~=~ bexp22
         return $ eq_bexp1 && eq_bexp2

    (ProcInst pid1 chids1 vexps1) ~=~ (ProcInst pid2 chids2 vexps2)  =  do
         eq_pid   <- return $ pid1 == pid2
         eq_chids <- return $ chids1 == chids2
         eq_vexps <- return $ vexps1 == vexps2 
         return $ eq_pid && eq_chids && eq_vexps 

    (Hide chids1 bexp1) ~=~ (Hide chids2 bexp2)  =  do
         eq_chids <- return $ (Set.fromList chids1) == (Set.fromList chids2)
         eq_bexp  <- bexp1 ~=~ bexp2
         return $ eq_chids && eq_bexp

    (ValueEnv ve1 bexp1) ~=~ (ValueEnv ve2 bexp2)  =  do
         eq_ve   <- return $ ve1 == ve2
         eq_bexp <- bexp1 ~=~ bexp2
         return $ eq_ve && eq_bexp

    (StAut stid1 ve1 trns1) ~=~ (StAut stid2 ve2 trns2)  =  do
         eq_stid <- return $ stid1 == stid2
         eq_ve   <- return $ ve1 == ve2
         eq_trns <- return $ trns1 == trns2
         return $ eq_stid && eq_ve && eq_trns

    _ ~=~ _  =  do
         return $ False

   
-- ----------------------------------------------------------------------------------------- --
-- ----------------------------------------------------------------------------------------- --
-- helper functions


-- ----------------------------------------------------------------------------------------- --
-- check elem of, with given momad equality

elemMby :: (Monad m) => (a -> a -> m Bool) -> a -> [a] -> m Bool
elemMby eqm e []      =  do
     return $ False
elemMby eqm e (x:xs)  =  do
     isin <- e `eqm` x
     if  isin
       then do return $ True
       else do elemMby eqm e xs


-- ----------------------------------------------------------------------------------------- --
-- make list unique, with given monad equality, in monad

nubMby :: (Monad m) => (a -> a -> m Bool) -> [a] -> m [a]
nubMby eqm []      =  do
     return $ []
nubMby eqm (x:xs)  =  do
     double <- elemMby eqm x xs
     if  double
       then do nubMby eqm xs
       else do xs' <- nubMby eqm xs
               return $ x:xs'


-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --

