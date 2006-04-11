module E.SSimplify(
    Occurance(..),
    simplifyE,
    simplifyDs,
    collectOccurance,
    programPruneOccurance,
    programSSimplify,
    SimplifyOpts(..)
    ) where

import Control.Monad.Identity
import Control.Monad.Writer
import Data.FunctorM
import Data.Generics
import Data.Monoid
import List hiding(delete,union)
import Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set

import Atom
import C.Prims
import DataConstructors
import Doc.PPrint
import E.Annotate
import E.E
import E.Program
import E.Eta
import E.Inline
import E.PrimOpt
import E.Rules
import E.Subst
import E.TypeCheck
import E.Values
import GenUtil
import Info.Types
import Name.Name
import Name.VConsts
import Options
import qualified E.Strictness as Strict
import qualified FlagOpts as FO
import qualified Info.Info as Info
import qualified Util.Seq as Seq
import Stats hiding(new,print,Stats)
import Support.CanType
import Support.FreeVars
import Util.Graph
import Util.HasSize
import Util.NameMonad
import Name.Id
import Util.ReaderWriter
import Util.SetLike as S

type Bind = (TVr,E)

data Occurance =
    Unused        -- ^ unused means a var is not used at the term level, but might be at the type level
    | Once        -- ^ Used at most once not inside a lambda or as an argument
    | OnceInLam   -- ^ used once inside a lambda
    | ManyBranch  -- ^ used once in several branches
    | Many        -- ^ used many or an unknown number of times
    | LoopBreaker -- ^ chosen as a loopbreaker, never inline
    deriving(Show,Eq,Ord,Typeable)


programPruneOccurance :: Program -> Program
programPruneOccurance prog =
    let dsIn = programDs prog
        (dsIn',fvs) = collectDs dsIn $ if progClosed prog then mempty else fromList $ map (flip (,) Many) (map (tvrIdent . fst) dsIn)
    in (programSetDs dsIn' prog)


newtype OM a = OM (ReaderWriter () OMap a)
    deriving(Monad,Functor,MonadWriter OMap)

unOM (OM a) = a

newtype OMap = OMap (IdMap Occurance)
   deriving(HasSize,SetLike,BuildSet (Id,Occurance),MapLike Id Occurance,Show,IsEmpty,Eq,Ord)

instance Monoid OMap where
    mempty = OMap mempty
    mappend (OMap a) (OMap b) = OMap (andOM a b)


maybeLetRec [] e = e
maybeLetRec ds e = ELetRec ds e

-- | occurance analysis

grump :: OM a -> OM (a,OMap)
grump m = censor (const mempty) (listen m)

collectOccurance :: E -> (E,IdMap Occurance) -- ^ (annotated expression, free variables mapped to their occurance info)
collectOccurance e = (fe,omap)  where
    (fe,OMap omap) = runReaderWriter (unOM (f e)) ()
    f e@ESort {} = return e
    f e@Unknown {} = return e
    f (EPi tvr@TVr { tvrIdent = 0, tvrType =  a} b) = arg $ do
        a <- f a
        b <- f b
        return (EPi tvr { tvrType = a } b)
    f (EPi tvr@(TVr { tvrIdent = n, tvrType =  a}) b) = arg $ do
        a <- f a
        (b,tfvs) <- grump (f b)
        case mlookup n tfvs of
            Nothing -> tell tfvs >>  return (EPi tvr { tvrIdent =  0, tvrType = a } b)
            Just occ -> tell (mdelete n tfvs) >> return (EPi (annb' tvr { tvrType = a }) b)
    f (ELit (LitCons n as t)) = arg $ do
        t <- f t
        as <- mapM f as
        return (ELit (LitCons n as t))
    f (ELit (LitInt i t)) = do
        t <- arg (f t)
        return $ ELit (LitInt i t)
    f (EPrim p as t) = arg $ do
        t <- f t
        as <- mapM f as
        return (EPrim p as t)
    f (EError err t) = do
        t <- arg (f t)
        return $ EError err t
    f e | (b,as@(_:_)) <- fromLam e = do
        (b',bvs) <- grump (f b)
        (as',asfv) <- grump (arg $ mapM ftvr as)
        let avs = bvs `andOM` asfv
            as'' = map (annbind' avs) as'
        tell $ inLam $ foldr mdelete avs (map tvrIdent as)
        return (foldr ELam b' as'')
    f e | Just (x,t) <- from_unsafeCoerce e  = do x <- f x ; t <- (arg (f t)); return (prim_unsafeCoerce x t)
    f (EVar tvr@TVr { tvrIdent = n, tvrType =  t}) = do
        tell $ msingleton n Once
        t <- arg (f t)
        return $ EVar tvr { tvrType = t }
    f e | (x,xs@(_:_)) <- fromAp e = do
        x <- f x
        xs <- arg (mapM f xs)
        return (foldl EAp x xs)
    f ec@ECase { eCaseScrutinee = e, eCaseBind = b, eCaseAlts = as, eCaseDefault = d} = do
        scrut' <- f e
        (d',fvb) <- grump (fmapM f d)
        (as',fvas) <- mapAndUnzipM (grump . alt) as
        let fidm = orMaps (fvb:fvas)
        ct <- arg $ f (eCaseType ec)
        b <- arg (ftvr b)
        tell $ mdelete (tvrIdent b) fidm
        return ec { eCaseScrutinee = scrut', eCaseAlts = as', eCaseBind = annbind' fidm b, eCaseType = ct, eCaseDefault = d'}
    f (ELetRec ds e) = do
        (e',OMap fve) <- grump (f e)
        let (ds''',fids) = collectDs ds fve
        tell (OMap fids)
        return (maybeLetRec ds''' e')
    f e = error $ "SSimplify.collectOcc.f: " ++ show e
    alt (Alt l e) = do
        (e',fvs) <- grump (f e)
        l <- arg (mapLitBindsM ftvr l)
        l <- arg (fmapM f l)
        let fvs' = foldr mdelete fvs (map tvrIdent $ litBinds l)
            l' = mapLitBinds (annbind' fvs) l
        tell fvs'
        return (Alt l' e')
    arg m = do
        let mm (OMap mp) = (OMap $ fmap (const Many) mp)
        censor mm m
    ftvr tvr = do
        tt <- f (tvrType tvr)
        return tvr { tvrType = tt }

-- delete any occurance info for non-let-bound vars to be safe
annb' tvr = tvrInfo_u (Info.delete Many) tvr
annbind' idm tvr = case mlookup (tvrIdent tvr) idm of
    Nothing -> annb' tvr { tvrIdent = 0 }
    Just _ -> annb' tvr

-- add ocucrance info
annbind idm tvr = case mlookup (tvrIdent tvr) idm of
    Nothing -> annb Unused tvr { tvrIdent = 0 }
    Just x -> annb x tvr
annb x tvr = tvrInfo_u (Info.insert x) tvr

mapLitBinds f (LitCons n es t) = LitCons n (map f es) t
mapLitBinds f (LitInt e t) = LitInt e t
mapLitBindsM f (LitCons n es t) = do
    es <- mapM f es
    return (LitCons n es t)
mapLitBindsM f (LitInt e t) = return $  LitInt e t

collectBinding :: Bind -> (Bind,IdMap Occurance)
collectBinding (t,e) = runIdentity $ do
    let (e',omap) = collectOccurance e
        rvars = freeVars (Info.fetch (tvrInfo t) :: ARules) :: IdMap TVr
        rvars' = fmap (const Many) rvars
    return ((t,e'),omap `andOM` rvars')

collectDs :: [Bind] -> (IdMap Occurance) -> ([Bind],IdMap Occurance)
collectDs ds fve = runIdentity $ do
    let ds' = map collectBinding ds
    let graph = newGraph ds' (\ ((t,_),_) -> tvrIdent t) (\ (_,fv) -> mkeys fv)
        rds = reachable graph (mkeys fve ++ [ tvrIdent t | (t,_) <- ds, getProperty prop_EXPORTED t])
        graph' = newGraph rds (\ ((t,_),_) -> tvrIdent t) (\ (_,fv) -> mkeys fv)
        (lb,ds'') =  findLoopBreakers (\ ((t,e),_) -> loopFunc t e) (const True) graph'
        fids = foldl andOM mempty (fve:snds ds'')
        ffids = fromList [ (tvrIdent t,lup t) | ((t,_),_) <- ds'' ]
        cycNodes = (fromList $ [ tvrIdent v | ((v,_),_) <- cyclicNodes graph'] :: IdSet)
        calcStrictInfo :: TVr -> TVr
        calcStrictInfo t
            | tvrIdent t `member` cycNodes = setProperty prop_CYCLIC t
            | otherwise = t
        lup t = case tvrIdent t `elem` [ tvrIdent t | ((t,_),_) <- lb] of
            True -> LoopBreaker
            False -> case getProperty prop_EXPORTED t of
                True -> Many
                False | Just r <- mlookup (tvrIdent t) fids -> r
        ds''' = [ (calcStrictInfo $ annbind ffids t ,e) | ((t,e),_) <- ds'']
        froo (t,e) = ((t {tvrType = t' },e),fvs) where
            (t',fvs) = collectOccurance (tvrType t)
        (ds'''',nfids) = unzip $ map froo ds'''
        nfid' = fmap (const Many) (mconcat nfids)
    return (ds'''',(nfid' `andOM` fids) S.\\ ffids)

-- TODO this should use the occurance info
-- loopFunc t _ | getProperty prop_PLACEHOLDER t = -100  -- we must not choose the placeholder as the loopbreaker
loopFunc t e = negate (baseInlinability t e)


inLam (OMap om) = OMap (fmap il om) where
    il Once = OnceInLam
    il _ = Many

andOM x y = munionWith andOcc x y
andOcc Unused x = x
andOcc x Unused = x
andOcc _ _ = Many

orMaps ms = OMap $ fmap orMany $ foldl (munionWith (++)) mempty (map (fmap (:[])) (map unOMap ms)) where
    unOMap (OMap m) = m

orMany [] = error "empty orMany"
orMany [x] = x
orMany xs = if all (== Once) xs then ManyBranch else Many



data SimplifyOpts = SimpOpts {
    so_noInlining :: Bool,                 -- ^ this inhibits all inlining inside functions which will always be inlined
    so_superInline :: Bool,                -- ^ whether to do superinlining
    so_boundVars :: IdMap E,
    so_rules :: Rules,
    so_dataTable :: DataTable,             -- ^ the data table
    so_exports :: [Int]
    }
    {-! derive: Monoid !-}


data Range = Done E | Susp E Subst
    deriving(Show,Eq,Ord)
type Subst = IdMap Range

type InScope = IdMap Binding

data Binding =
    NotAmong [Name]
    | IsBoundTo { bindingOccurance :: Occurance, bindingE :: E, bindingCheap :: Bool }
    | NotKnown
    deriving(Ord,Eq)
    {-! derive: is !-}

isBoundTo o e = IsBoundTo {
    bindingOccurance = o,
    bindingE = e,
    bindingCheap = isCheap e
    }

data Env = Env {
    envInScope :: IdMap Binding,
    envTypeMap :: IdMap E
    }
    {-! derive: Monoid, update !-}

applySubst :: Subst -> IdMap a -> E -> E
applySubst s nn = applySubst' s where
    nn' = fmap (const Nothing) s `mappend` fmap (const Nothing) nn
    applySubst' s = substMap'' (tm `mappend` nn') where
        tm = fmap g s
        g (Done e) = Just e
        g (Susp e s') = Just $ applySubst' s' e

dosub sub inb e = coerceOpt return $ applySubst sub (envInScope inb) e

simplifyE :: SimplifyOpts -> E -> (Stat,E)
simplifyE sopts e = (stat,e') where
    (stat,[(_,e')]) =  simplifyDs sopts [(tvrSilly,e)]

programSSimplify :: SimplifyOpts -> Program -> Program
programSSimplify sopts prog =
    let (stats,dsIn) = simplifyDs sopts (programDs prog)
    in (programSetDs dsIn prog) { progStats = progStats prog `mappend` stats }


simplifyDs :: SimplifyOpts -> [(TVr,E)] -> (Stat,[(TVr,E)])
simplifyDs sopts dsIn = (stat,dsOut) where

    getType e = infertype (so_dataTable sopts) e
    collocc dsIn = do
        --let (dsIn',fvs) = collectDs dsIn (fromList $ map (flip (,) Many) (map (tvrIdent . fst) dsIn))
        --addNames (mkeys fvs)
        --addNames (map tvrIdent $ Map.keys occ)
        --let occ' = Map.mapKeysMonotonic tvrIdent occ
        --    dsIn'' = runIdentity $ annotateDs mempty (\t nfo -> return $ maybe (Info.delete Many nfo) (flip Info.insert nfo) (mlookup t occ')) (\_ -> return) (\_ -> return) dsIn'
        return dsIn
    initialB = mempty { envInScope =  fmap (\e -> isBoundTo Many e) (so_boundVars sopts) }
    initialB' = mempty { envInScope =  fmap (\e -> NotKnown) (so_boundVars sopts) }
    (dsOut,stat)  = runIdentity $ runStatT (runIdNameT doit)
    doit = do
        dsIn <- sequence [etaExpandDef' (so_dataTable sopts) t e | (t,e) <- dsIn ]
        ds' <- collocc dsIn
        let g (t,e) = do
                e' <- if forceInline t then
                        f e mempty initialB'  -- ^ do not inline into functions which themself will be inlined
                            else f e mempty initialB
                return (t,e')
        mapM g ds'
    go :: E -> Env -> IdNameT (StatT Identity) E
    go e inb = do
        let (e',_) = collectOccurance e
        f e' mempty inb
    f :: E -> Subst -> Env -> IdNameT (StatT Identity) E
    f e sub inb | (EVar v,xs) <- fromAp e = do
        xs' <- mapM (dosub sub inb) xs
        case mlookup (tvrIdent v) sub of
            Just (Done e) -> h e xs' inb   -- e is var or trivial
            Just (Susp e s) -> do
                e' <- f e s inb
                h e' xs' inb
                --app (e',xs')
            Nothing -> h (EVar v) xs' inb
            -- Nothing -> error $ "Var with no subst: " ++ show e ++ "\n" ++  show  sub -- h (EVar v) xs' inb
    f e sub inb | (x,xs) <- fromAp e = do
        eed <- etaExpandDef (so_dataTable sopts) tvr { tvrIdent = 0 } e
        case eed of
            Just (_,e) -> f e sub inb -- go e inb
            Nothing -> do
                xs' <- mapM (dosub sub inb) xs
                x' <- g x sub inb
                x'' <- coerceOpt return x'
                x <- primOpt' (so_dataTable sopts) x''
                h x xs' inb
    g (EPrim a es t) sub inb = do
        es' <- mapM (dosub sub inb) es
        t' <- dosub sub inb t
        return $ EPrim a es' t'
    g (ELit (LitCons n es t)) sub inb = do
        es' <- mapM (dosub sub inb) es
        t' <- dosub sub inb t
        return $ ELit (LitCons n es' t')
    g (ELit (LitInt n t)) sub inb = do
        t' <- dosub sub inb t
        return $ ELit (LitInt n t')
    g e@(EPi (TVr { tvrIdent = n }) b) sub inb = do
        addNames [n]
        e' <- dosub sub inb e
        return e'
    g (EError s t) sub inb = do
        t' <- dosub sub inb t
        return $ EError s t'
    g ec@ECase { eCaseScrutinee = e, eCaseBind = b, eCaseAlts = as, eCaseDefault = d} sub inb = do
        addNames (map tvrIdent $ caseBinds ec)
        e' <- f e sub inb
        doCase e' (eCaseType ec) b as d sub inb
    g (ELam v e) sub inb  = do
        addNames [tvrIdent v]
        v' <- nname v sub inb
        e' <- f e (minsert (tvrIdent v) (Done $ EVar v') sub) (envInScope_u (minsert (tvrIdent v') NotKnown) inb)
        return $ ELam v' e'
--    g (ELetRec [] e) sub inb = g e sub inb
    g (ELetRec ds e) sub inb = do
        addNames $ map (tvrIdent . fst) ds
        let z (t,EVar t') | t == t' = do    -- look for simple loops and replace them with errors.
                t'' <- nname t sub inb
                mtick $ "E.Simplify.<<loop>>.{" ++ showName (tvrIdent t) ++ "}"
                return (tvrIdent t,Many,t'',EError "<<loop>>" (getType t))
            z (t,e) = do
                t' <- nname t sub inb
                case Info.lookup (tvrInfo t) of
                    _ | forceNoinline t -> return (tvrIdent t,LoopBreaker,t',e)
                    Just Once -> return (tvrIdent t,Once,error $ "Once: " ++ show t,e)
                    Just n -> return (tvrIdent t,n,t',e)
                    -- We don't want to inline things we don't have occurance info for because they might lead to an infinite loop. hopefully the next pass will fix it.
                    Nothing -> return (tvrIdent t,LoopBreaker,t',e)
                    -- Nothing -> error $ "No Occurance info for " ++ show t
            w ((t,Once,t',e):rs) sub inb ds = do
                mtick $ "E.Simplify.inline.Once.{" ++ showName t ++ "}"
                w rs (minsert t (Susp e sub) sub) inb ds
            w ((t,n,t',e):rs) sub inb ds = do
                e' <- f e sub inb
                case isAtomic e' && n /= LoopBreaker of
                    True -> do
                        when (n /= Unused) $ mtick $ "E.Simplify.inline.Atomic.{" ++ showName t ++ "}"
                        w rs (minsert t (Done e') sub) (envInScope_u (minsert (tvrIdent t') (isBoundTo n e')) inb) ((t',e'):ds)
                    -- False | worthStricting e', Strict <- Info.lookup (tvrInfo t') -> w rs sub
                    False -> w rs sub (if n /= LoopBreaker then (envInScope_u (minsert (tvrIdent t') (isBoundTo n e')) inb) else inb) ((t',e'):ds)
            w [] sub inb ds = return (ds,sub,inb)
        ds <- sequence [ etaExpandDef' (so_dataTable sopts) t e | (t,e) <- ds]
        s' <- mapM z ds
        let
            sub'' = {- Map.fromList [ (t,Susp e sub'') | (t,Once,_,e) <- s'] `Map.union`-} (fromList [ (t,Done (EVar t'))  | (t,n,t',_) <- s', n /= Once]) `union` sub
        (ds',sub',inb') <- w s' sub'' (envInScope_u (fromList [ (tvrIdent t',NotKnown) | (_,n,t',_) <- s', n /= Once] `union`) inb) []
        e' <- f e sub' inb'
        case ds' of
            [(t,e)] | worthStricting e, Just (Strict.S _) <- Info.lookup (tvrInfo t), not (getProperty prop_CYCLIC t) -> do
                mtick "E.Simplify.strictness.let-to-case"
                return $ eStrictLet t e e'
            _ -> do
                let fn ds (ELetRec ds' e) | not (hasRepeatUnder fst (ds ++ ds')) = fn (ds' ++ ds) e
                    fn ds e = f ds (Set.fromList $ fsts ds) [] False where
                        f ((t,ELetRec ds' e):rs) us ds b | all (not . (`Set.member` us)) (fsts ds') = f ((t,e):rs) (Set.fromList (fsts ds') `Set.union` us) (ds':ds) True
                        f (te:rs) us ds b = f rs us ([te]:ds) b
                        f [] _ ds True = fn (concat ds) e
                        f [] _ ds False = (concat ds,e)
                let (ds'',e'') = fn ds' e'
                --when (hasRepeatUnder fst ds'') $ fail "hasRepeats!"
                mticks  (length ds'' - length ds') (toAtom $ "E.Simplify.let-coalesce")
                return $ eLetRec ds'' e''
                {-
                let z (v,ELetRec ds e) = (ds,(v,e))
                    z (v,e) = ([],(v,e))
                    (ds''',ds'') = unzip (map z ds')
                    nds = (concat ds''' ++ ds'')
                --mticks (length (concat ds''')) (toAtom $ "E.Simplify.let-coalesce.{" ++ unwords (sort (map tvrShowName $ map fst (concat ds'''))) ++ "}")

                if hasRepeatUnder fst nds then
                    return $ eLetRec ds' e'
                  else do
                    mticks (length (concat ds''')) (toAtom $ "E.Simplify.let-coalesce")
                    return $ eLetRec nds  e'
                  -}
    g e _ _ = error $ "SSimplify.simplify.g: " ++ show e ++ "\n" ++ pprint e
    showName t | odd t = tvrShowName (tVr t Unknown)
             | otherwise = "(epheremal)"

    nname tvr@(TVr { tvrIdent = n, tvrType =  t}) sub inb  = do
        t' <- dosub sub inb t
        let t'' = substMap'' (fmap (\ IsBoundTo { bindingE = e } -> Just e) $ mfilter isIsBoundTo (envInScope inb)) t'
        n' <- uniqueName n
        return $ tvr { tvrIdent = n', tvrType =  t'' }
--        case n `Map.member` inb of
--            True -> do
--                n' <- newName
--                return $ TVr n' t'
--            False -> do
--                n' <- uniqueName n
--                return $ TVr n' t'

    -- TODO - case simplification

    doCase (ELetRec ds e) t b as d sub inb = do
        mtick "E.Simplify.let-from-case"
        e' <- doCase e t b as d sub inb
        return $ substLet' ds e'

    doCase (EVar v) t b as d sub inb |  Just IsBoundTo { bindingE = ELit l } <- mlookup (tvrIdent v) (envInScope inb)  = doConstCase l t  b as d sub inb
    doCase (ELit l) t b as d sub inb  = doConstCase l t b as d sub inb

    doCase (EVar v) t b as d sub inb | Just IsBoundTo { bindingE = e } <- mlookup (tvrIdent v) (envInScope inb) , isBottom e = do
        mtick "E.Simplify.case-of-bottom'"
        t' <- dosub sub inb t
        return $ prim_unsafeCoerce (EVar v) t'

    doCase ic@ECase { eCaseScrutinee = e, eCaseBind =  b, eCaseAlts =  as, eCaseDefault =  d } t b' as' d' sub inb | length (filter (not . isBottom) (caseBodies ic)) <= 1 || all whnfOrBot (caseBodies ic)  || all whnfOrBot (caseBodies emptyCase { eCaseAlts = as', eCaseDefault = d'} )  = do
        mtick (toAtom "E.Simplify.case-of-case")
        let f (Alt l e) = do
                e' <- doCase e t b' as' d' sub (envInScope_u (fromList [ (n,NotKnown) | TVr { tvrIdent = n } <- litBinds l ] `union`) inb)
                return (Alt l e')
            --g e >>= return . Alt l
            g x = doCase x t b' as' d' sub (envInScope_u (minsert (tvrIdent b) NotKnown) inb)
        as'' <- mapM f as
        d'' <- fmapM g d
        t' <- dosub sub t
        return ECase { eCaseScrutinee = e, eCaseType = t', eCaseBind = b, eCaseAlts = as'', eCaseDefault = d''} -- XXX     -- we duplicate code so continue for next renaming pass before going further.
    doCase e t b as d sub inb | isBottom e = do
        mtick "E.Simplify.case-of-bottom"
        t' <- dosub sub inb t
        return $ prim_unsafeCoerce e t'

    doCase e t b as@(Alt (LitCons n _ _) _:_) (Just d) sub inb | Just ss <- getSiblings (so_dataTable sopts) n, length ss <= length as = do
        mtick "E.Simplify.case-no-default"
        doCase e t b as Nothing sub inb
    doCase e t b as (Just d) sub inb | te /= tWorld__, (ELit (LitCons cn _ _)) <- followAliases dt te, Just Constructor { conChildren = Just cs } <- getConstructor cn dt, length as == length cs - 1 || (False && length as < length cs && isAtomic d)  = do
        let ns = [ n | Alt ~(LitCons n _ _) _ <- as ]
            ls = filter (`notElem` ns) cs
            f n = do
                con <- getConstructor n dt
                let g t = do
                        n <- newName
                        return $ tVr n t
                ts <- mapM g (slotTypes (so_dataTable sopts) n te)
                let wtd = ELit $ LitCons n (map EVar ts) te
                return $ Alt (LitCons n ts te) (eLet b wtd d)
        mtick $ "E.Simplify.case-improve-default.{" ++ show (sort ls) ++ "}"
        ls' <- mapM f ls
        doCase e t b (as ++ ls') Nothing sub inb
        where
        te = getType e
        dt = (so_dataTable sopts)
    doCase e _ b [] (Just d) sub inb | not (isLifted e || isUnboxed (getType e)) = do
        mtick "E.Simplify.case-unlifted"
        b' <- nname b sub inb
        d' <- f d (minsert (tvrIdent b) (Done (EVar b')) sub) (envInScope_u  (minsert (tvrIdent b') (isBoundTo Many e)) inb)
        return $ eLet b' e d'
    -- atomic unboxed values may be substituted or discarded without replicating work or affecting program semantics.
    doCase e _ b [] (Just d) sub inb | isUnboxed (getType e), isAtomic e = do
        mtick "E.Simplify.case-atomic-unboxed"
        f d (minsert (tvrIdent b) (Susp e sub) sub) inb
    doCase (EVar v) _ b [] (Just d) sub inb | Just (NotAmong _) <-  mlookup (tvrIdent v) (envInScope inb)  = do
        mtick "E.Simplify.case-evaled"
        d' <- f d (minsert (tvrIdent b) (Done (EVar v)) sub) inb
        return d'
    doCase scrut _ v [] (Just sc@ECase { eCaseScrutinee = EVar v'} ) sub inb | v == v', tvrIdent v `notMember` (freeVars (caseBodies sc) :: IdSet)  = do
        mtick "E.Simplify.case-default-case"
        f sc { eCaseScrutinee = scrut } sub inb
    doCase e t b as d sub inb = do
        b' <- nname b sub inb
        let dd e' = f e' (minsert (tvrIdent b) (Done $ EVar b') sub) (envInScope_u (newinb `union`) inb) where
                na = NotAmong [ n | Alt (LitCons n _ _) _ <- as]
                newinb = fromList [ (n,na) | EVar (TVr { tvrIdent = n }) <- [e,EVar b']]
            da (Alt (LitInt n t) ae) = do
                t' <- dosub sub inb t
                let p' = LitInt n t'
                e' <- f ae sub (mins e (patToLitEE p') inb)
                return $ Alt p' e'
            da (Alt (LitCons n ns t) ae) = do
                t' <- dosub sub inb t
                ns' <- mapM (\v -> nname v sub inb) ns
                let p' = LitCons n ns' t'
                    nsub = fromList [ (n,Done (EVar t))  | TVr { tvrIdent = n } <- ns | t <- ns' ]
                    ninb = fromList [ (n,NotKnown)  | TVr { tvrIdent = n } <- ns' ]
                e' <- f ae (nsub `union` sub) (envInScope_u (ninb `union`) $ mins e (patToLitEE p') inb)
                return $ Alt p' e'
            mins (EVar v) e = envInScope_u (minsert (tvrIdent v) (isBoundTo Many e))
            mins _ _ = id

        d' <- fmapM dd d
        as' <- mapM da as
        t' <- dosub sub inb t
        return ECase { eCaseScrutinee = e, eCaseType = t', eCaseBind =  b', eCaseAlts = as', eCaseDefault = d'}

    doConstCase l t b as d sub inb = do
        t' <- dosub sub inb t
        mr <- match l as (b,d)
        case mr of
            Just (bs,e) -> do
                let bs' = [ x | x@(TVr { tvrIdent = n },_) <- bs, n /= 0]
                binds <- mapM (\ (v,e) -> nname v sub inb >>= return . (,,) e v) bs'
                e' <- f e (fromList [ (n,Done $ EVar nt) | (_,TVr { tvrIdent = n },nt) <- binds] `union` sub)   (envInScope_u (fromList [ (n,isBoundTo Many e) | (e,_,TVr { tvrIdent = n }) <- binds] `union`) inb)
                return $ eLetRec [ (v,e) | (e,_,v) <- binds ] e'
            Nothing -> do
                return $ EError ("match falls off bottom: " ++ pprint l) t'

    match m@(LitCons c xs _) ((Alt (LitCons c' bs _) e):rs) d | c == c' = do
        mtick (toAtom $ "E.Simplify.known-case." ++ show c )
        return $ Just ((zip bs xs),e)
         | otherwise = match m rs d
    match m@(LitInt a _) ((Alt (LitInt b _) e):rs) d | a == b = do
        mtick (toAtom $ "E.Simplify.known-case." ++ show a)
        return $ Just ([],e)
         | otherwise = match m rs d
    match l [] (b,Just e) = do
        mtick (toAtom "E.Simplify.known-case._")
        return $ Just ([(b,ELit l)],e)
    --match m [] (_,Nothing) = error $ "End of match: " ++ show m
    match m [] (_,Nothing) = do
        mtick (toAtom "E.Simplify.known-case.unmatch")
        return Nothing
    match m as d = error $ "Odd Match: " ++ show ((m,getType m),as,d)


    applyRule v xs inb  = do
        z <- builtinRule v xs
        let lup x = case mlookup x (envInScope inb) of
                Just IsBoundTo { bindingE = e } -> Just e
                _ -> Nothing
        case z of
            Nothing | fopts FO.Rules -> applyRules lup (Info.fetch (tvrInfo v)) xs
            x -> return x
    h (EVar v) xs' inb = do
        z <- applyRule v xs' inb
        case (z,forceNoinline v) of
            (Just (x,xs),_) -> didInline inb x xs  -- h x xs inb
            (_,True) -> app (EVar v, xs')
            _ -> case mlookup (tvrIdent v) (envInScope inb) of
                Just IsBoundTo { bindingOccurance = LoopBreaker } -> appVar v xs'
                Just IsBoundTo { bindingOccurance = Once } -> error "IsBoundTo: Once"
                Just IsBoundTo { bindingE = e } | forceInline v -> do
                    mtick  (toAtom $ "E.Simplify.inline.forced.{" ++ tvrShowName v  ++ "}")
                    didInline inb e xs'
                Just IsBoundTo { bindingOccurance = OnceInLam, bindingE = e, bindingCheap = True } | someBenefit v e xs' -> do
                    mtick  (toAtom $ "E.Simplify.inline.OnceInLam.{" ++ showName (tvrIdent v)  ++ "}")
                    didInline inb e xs'
                Just IsBoundTo { bindingOccurance = ManyBranch, bindingE = e } | multiInline v e xs' -> do
                    mtick  (toAtom $ "E.Simplify.inline.ManyBranch.{" ++ showName (tvrIdent v)  ++ "}")
                    didInline inb  e xs'
                Just IsBoundTo { bindingOccurance = Many, bindingE = e, bindingCheap = True } | multiInline v e xs' -> do
                    mtick  (toAtom $ "E.Simplify.inline.Many.{" ++ showName (tvrIdent v)  ++ "}")
                    didInline inb  e xs'
                Just _ -> appVar v xs'
                Nothing  -> appVar v xs'
                -- Nothing | tvrIdent v `Set.member` exports -> app (EVar v,xs')
                -- Nothing -> error $ "Var not in scope: " ++ show v
    h e xs' inb = do app (e,xs')
    didInline inb z zs = do
        e <- app (z,zs)
        go e inb
    appVar v xs = do
        me <- etaExpandAp (so_dataTable sopts) v xs
        case me of
            Just e -> return e
            Nothing -> app (EVar v,xs)



someBenefit _ ELit {} _ = True
someBenefit _ EPrim {} _ = True
someBenefit _ e xs | f e xs = True where
    f (ELam _ e) (x:xs) = f e xs
    f ELam {} [] = False
    f _ _ = True
someBenefit v e xs = False

multiInline _ e xs | isSmall (f e xs) = True  where -- should be noSizeIncrease
    f e [] = e
    f (ELam _ e) (_:xs) = f e xs
    f e xs = foldl EAp e xs
multiInline v e xs | not (someBenefit v e xs) = False
multiInline _ e xs = length xs + 2 >= (nsize + if safeToDup b then negate 4 else 0)  where
    (b,as) = fromLam e
    nsize = size b + abs (length as - length xs)
    size e | (x,xs) <- fromAp e = size' x + length xs
    size' (EVar _) = 1
    size' (ELit _) = 1
    size' (EPi _ _) = 1
    size' (ESort _) = 1
    size' (EPrim _ _ _) = 1
    size' (EError _ _) = -1
    size' ec@ECase {} | EVar v <- eCaseScrutinee ec, v `elem` as = sum (map size (caseBodies ec)) - 3
    size' ec@ECase {} = size (eCaseScrutinee ec) + sum (map size (caseBodies ec))
    size' (ELetRec ds e) = size e + sum (map (size . snd) ds)
    size' _ = 2


worthStricting EError {} = True
worthStricting ELit {} = False
worthStricting ELam {} = False
worthStricting x = sortTermLike x


coerceOpt :: MonadStats m =>  (E -> m E) -> E -> m E
coerceOpt fn e = do
    let (n,e',p) = unsafeCoerceOpt e
    n `seq` stat_unsafeCoerce `seq` mticks n stat_unsafeCoerce
    e'' <- fn e'
    return (p e'')

stat_unsafeCoerce = toAtom "E.Simplify.unsafeCoerce"

