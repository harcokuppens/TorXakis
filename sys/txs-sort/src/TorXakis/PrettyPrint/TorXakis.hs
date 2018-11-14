{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  TorXakis.PrettyPrint.TorXakis
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
-- 
-- Maintainer  :  pierre.vandelaar@tno.nl (Embedded Systems Innovation by TNO)
-- Stability   :  experimental
-- Portability :  portable
--
-- PrettyPrinter for TorXakis output
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module TorXakis.PrettyPrint.TorXakis
( -- * Pretty Print Options
  Options (..)
  -- * Pretty Print class for TorXakis
, PrettyPrint (..)
  -- Pretty Print Output for TorXakis
, TxsString (..)
)
where
import           Control.DeepSeq     (NFData)
import           Data.Data           (Data)
import qualified Data.Text           as T
import           GHC.Generics        (Generic)


-- | The data type that represents the options for pretty printing.
data Options = Options { -- | May a definition cover multiple lines?
                         multiline :: Bool
                         -- | Should a definition be short? E.g. by combining of arguments of the same sort.
                       , short     :: Bool
                       }
    deriving (Eq, Ord, Show, Read, Generic, NFData, Data)

-- | Enables pretty printing in a common way.
class PrettyPrint a where
    prettyPrint :: Options -> a -> TxsString

-- | The data type that represents the output for pretty printing in TorXakis format.
newtype TxsString = TxsString { toText :: T.Text }
    deriving (Eq, Ord, Show, Read, Generic, NFData, Data)