{-------------------------------------------------------------------------------

        Copyright:              Mark Jones and The Hatchet Team
                                (see file Contributors)

        Module:                 Type

        Description:            Manipulation of types

                                The main tasks implemented by this module are:
                                        - type substitution
                                        - type unification
                                        - type matching
                                        - type quantification

        Primary Authors:        Mark Jones and Bernie Pope

        Notes:                  See the file License for license information

                                Large parts of this module were derived from
                                the work of Mark Jones' "Typing Haskell in
                                Haskell", (http://www.cse.ogi.edu/~mpj/thih/)

-------------------------------------------------------------------------------}

module Type (
    Types (..)
    ) where

import Control.Monad.Error
import Control.Monad.Writer
import Data.IORef
import List    (union, nub)
import qualified Data.Map as Map

import GenUtil
import Name.Name
import Name.VConsts
import Representation
import Support.CanType


--------------------------------------------------------------------------------

class Types t where
  apply :: Subst -> t -> t
  tv    :: t -> [Tyvar]

-----------------------------------------------------------------------------


instance Types t => Types (Qual t) where
  apply s (ps :=> t) = apply s ps :=> apply s t
  tv (ps :=> t)      = tv ps `union` tv t

instance Types Pred where
  apply s (IsIn c t) = IsIn c (apply s t)
  apply s (IsEq t1 t2) = IsEq (apply s t1) (apply s t2)
  tv (IsIn c t)      = tv t
  tv (IsEq t1 t2)      = tv t1 ++ tv t2

--------------------------------------------------------------------------------

-- substitutions
type Subst = Map.Map Tyvar Type

nullSubst  :: Subst
nullSubst   = Map.empty

(+->)      :: Tyvar -> Type -> Subst
u +-> t     = Map.singleton u t

instance Types Type where
  apply s x@(TVar var)
     = case Map.lookup var s of
          Just t  -> t
          Nothing -> x
  apply s (TAp l r)     = TAp (apply s l) (apply s r)
  apply s (TArrow l r)  = TArrow (apply s l) (apply s r)
  apply s (TAssoc c cas eas)  = TAssoc c (map (apply s) cas) (map (apply s) cas)
  apply _ t         = t

  tv (TVar u)      = [u]
  tv (TAp l r)     = tv l `union` tv r
  tv (TArrow l r)  = tv l `union` tv r
  tv (TAssoc _ cas eas) = tv cas `union` tv eas
  tv _             = []

instance Types a => Types [a] where
  apply s = map (apply s)              -- it may be worth using a cached version of apply in this circumstance?
  tv      = nub . concat . map tv

infixr 4 @@
(@@)       :: Subst -> Subst -> Subst
s1 @@ s2
   =(Map.union s1OverS2 s1)
   where
   s1OverS2 = mapSubstitution s1 s2

merge      :: Monad m => Subst -> Subst -> m Subst
merge s1 s2 = if agree then return s else fail $ "merge: substitutions don't agree"
 where
 s = Map.union s1 s2
 agree = all (\v -> (Map.lookup v s1 :: Maybe Type) == Map.lookup v s2 ) $ map fst $ Map.toList $ s1 `Map.intersection` s2
-- agree = all (\v -> apply s1 (TVar v) == apply s2 (TVar v)) $ map fst $ toListFM $ s1 `intersectFM` s2



mapSubstitution s fm =(Map.map (\v -> apply s v) fm)


match :: Monad m => Type -> Type -> m Subst

match x y = do match' x y

match' (TAp l r) (TAp l' r')
   = do sl <- match l l'
        sr <- match r r'
        merge sl sr

match' (TArrow l r) (TArrow l' r')
   = do sl <- match l l'
        sr <- match r r'
        merge sl sr

match' (TVar u) t
   | getType u == getType t = return (u +-> t)

match' (TCon tc1) (TCon tc2)
   | tc1==tc2         = return nullSubst

match' t1 t2           = fail $ "match: " ++ show (t1,t2)



