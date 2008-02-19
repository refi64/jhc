module Ho.Collected(
    CollectedHo(..),
    choHo
    )where

import Data.Monoid
import Control.Monad.Identity

import Util.SetLike
import Ho.Type
import E.E
import DataConstructors
import Info.Types
import E.Annotate
import qualified Info.Info as Info
import qualified Data.Map as Map

instance Monoid CollectedHo where
    mempty = CollectedHo {
        choExternalNames = mempty,
        choOrphanRules = mempty,
        choHoMap = Map.singleton "Prim@" pho,
        choVarMap = mempty
        } where pho = mempty { hoBuild = mempty { hoDataTable = dataTablePrims } }
    a `mappend` b = CollectedHo {
        choExternalNames = choExternalNames a `mappend` choExternalNames b,
        choVarMap = choVarMap a `mergeChoVarMaps` choVarMap b,
        choOrphanRules = choOrphanRules a `mappend` choOrphanRules b,
        choHoMap = Map.union (choHoMap a) (choHoMap b)
        }

choHo cho = hoBuild_u (hoEs_u f) . mconcat . Map.elems $ choHoMap cho where
    f ds = runIdentity $ annotateDs mmap  (\_ -> return) (\_ -> return) (\_ -> return) (map g ds) where
        mmap = mfilterWithKey (\k _ -> (k `notElem` (map (tvrIdent . fst) ds))) (choVarMap cho)
    g (t,e) = case mlookup (tvrIdent t) (choVarMap cho) of
        Just (Just (EVar t')) -> (t',e)
        _ -> (t,e)
    ae = runIdentity . annotate (choVarMap cho) (\_ -> return) (\_ -> return) (\_ -> return)

-- this will have to merge rules and properties.
mergeChoVarMaps :: IdMap (Maybe E) -> IdMap (Maybe E) -> IdMap (Maybe E)
mergeChoVarMaps x y = munionWith f x y where
    f (Just (EVar x)) (Just (EVar y)) = Just . EVar $ merge x y
    f x y = error "mergeChoVarMaps: bad merge."
    merge ta tb = ta { tvrInfo = minfo' }   where
        minfo = tvrInfo ta `mappend` tvrInfo tb
        minfo' = dex (undefined :: ARules) . dex (undefined :: Properties) $ minfo
        dex dummy y = g (Info.lookup (tvrInfo tb) `asTypeOf` Just dummy) where
            g Nothing = y
            g (Just x) = Info.insertWith mappend x y

