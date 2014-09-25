{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}

module SAWScript.MGU where

import qualified SAWScript.AST as A
import SAWScript.AST
import SAWScript.Compiler

import Control.Applicative

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Identity
import Data.Maybe (mapMaybe)
import qualified Data.Map as M
import qualified Data.Set as S

-- Subst {{{

newtype Subst = Subst { unSubst :: M.Map TyVar Type } deriving (Show)

(@@) :: Subst -> Subst -> Subst
s2@(Subst m2) @@ (Subst m1) = Subst $ m1' `M.union` m2
  where
  m1' = fmap (appSubst s2) m1

emptySubst :: Subst
emptySubst = Subst M.empty

singletonSubst :: TyVar -> Type -> Subst
singletonSubst tv t = Subst $ M.singleton tv t

listSubst :: [(TyVar,Type)] -> Subst
listSubst = Subst . M.fromList

-- }}}

-- mgu {{{

failMGU :: String -> Either String a
failMGU = Left

assert :: Bool -> String -> Either String ()
assert b msg = unless b $ failMGU msg

mgu :: LName -> Type -> Type -> Either String Subst
mgu m (TyVar tv) t2 = bindVar m tv t2
mgu m t1 (TyVar tv) = bindVar m tv t1
mgu m r1@(TyRecord ts1) r2@(TyRecord ts2) = do
  assert (M.keys ts1 == M.keys ts2) $
    "mismatched record fields: " ++ pShow r1 ++ " and " ++ pShow r2
  mgus m (M.elems ts1) (M.elems ts2)
mgu m (TyCon tc1 ts1) (TyCon tc2 ts2) = do
  assert (tc1 == tc2) $
    "mismatched type constructors: " ++ pShow tc1 ++ " and " ++ pShow tc2
  mgus m ts1 ts2
mgu m t1 t2 = failMGU $ "type mismatch: " ++ pShow t1 ++ " and " ++ pShow t2 ++ " at " ++ show m

mgus :: LName -> [Type] -> [Type] -> Either String Subst
mgus _ [] [] = return emptySubst
mgus m (t1:ts1) (t2:ts2) = do
  s <- mgu m t1 t2
  s' <- mgus m (map (appSubst s) ts1) (map (appSubst s) ts2)
  return (s' @@ s)
mgus m _ _ = failMGU $ "type mismatch in constructor arity at" ++ show m

bindVar :: LName -> TyVar -> Type -> Either String Subst
bindVar _ (FreeVar i) (TyVar (FreeVar j))
  | i == j    = return emptySubst
bindVar m tv@(FreeVar _) t
  | tv `S.member` freeVars t = failMGU ("occurs check failMGUs " ++ " at " ++ show m)
  | otherwise                = return $ singletonSubst tv t

bindVar _ tv@(BoundVar _) t@(TyVar (FreeVar _)) = return $ singletonSubst tv t

bindVar _ (BoundVar n) (TyVar (BoundVar m))
  | n == m  = return emptySubst

bindVar m e1 e2 = failMGU $ "generality mismatch: " ++ pShow e1 ++ " and " ++ pShow e2 ++ " at " ++ show m

-- }}}

-- FreeVars {{{

class FreeVars t where
  freeVars :: t -> S.Set TyVar

instance (Ord k, FreeVars a) => FreeVars (M.Map k a) where
  freeVars = freeVars . M.elems

instance (FreeVars a) => FreeVars [a] where
  freeVars = S.unions . map freeVars

instance FreeVars Type where
  freeVars t = case t of
    TyCon _ ts  -> freeVars ts
    TyRecord fs -> freeVars fs
    TyVar tv    -> S.singleton tv

instance FreeVars Schema where
  freeVars (Forall ns t) = freeVars t S.\\ (S.fromList $ map BoundVar ns)

-- }}}

-- TI Monad {{{

newtype TI a = TI { unTI :: ReaderT RO (StateT RW Identity) a }
                        deriving (Functor,Applicative,Monad)

data RO = RO
  { typeEnv :: M.Map (Located Name) Schema
  , curMod  :: ModuleName
  }

emptyRO :: ModuleName -> RO
emptyRO m = RO { typeEnv = M.empty, curMod = m }

data RW = RW
  { nameGen :: Integer
  , subst   :: Subst
  , errors  :: [String]
  }

emptyRW :: RW
emptyRW = RW 0 emptySubst []

newType :: TI Type
newType = do
  rw <- TI get
  TI $ put $ rw { nameGen = nameGen rw + 1 }
  return $ TyVar $ FreeVar $ nameGen rw

freshInst :: Schema -> TI Type
freshInst (Forall ns t) = do nts <- mapM (\n -> (,) <$> pure n <*> newType) ns
                             return (instantiate nts t)

appSubstM :: AppSubst t => t -> TI t
appSubstM t = do
  s <- TI $ gets subst
  return $ appSubst s t

recordError :: String -> TI ()
recordError err = TI $ modify $ \rw ->
  rw { errors = err : errors rw }

unify :: LName -> Type -> Type -> TI ()
unify m t1 t2 = do
  t1' <- appSubstM t1
  t2' <- appSubstM t2
  case mgu m t1' t2' of
    Right s -> TI $ modify $ \rw -> rw { subst = s @@ subst rw }
    Left e -> recordError $ unlines
                [ "type mismatch: " ++ pShow t1 ++ " and " ++ pShow t2
                , " at " ++ show m
                , e
                ]

bindSchema :: Located Name -> Schema -> TI a -> TI a
bindSchema n s m = TI $ local (\ro -> ro { typeEnv = M.insert n s $ typeEnv ro })
  $ unTI m

bindSchemas :: [(Located Name, Schema)] -> TI a -> TI a
bindSchemas bs m = foldr (uncurry bindSchema) m bs

bindDecl :: Decl -> TI a -> TI a
bindDecl (Decl _ Nothing _) m = m
bindDecl (Decl n (Just s) _) m = bindSchema n s m

bindDecls :: [Decl] -> TI a -> TI a
bindDecls ds m = foldr bindDecl m ds

-- deprecated
bindTopSchemas :: [LBind Schema] -> TI a -> TI a
bindTopSchemas ds k = bindSchemas ds k

-- deprecated
bindLocalSchemas :: [LBind Schema] -> TI a -> TI a
bindLocalSchemas ds k = bindSchemas ds k

curModName :: TI ModuleName
curModName = TI $ asks curMod

lookupVar :: Located Name -> TI Type
lookupVar n = do
  env <- TI $ asks typeEnv
  case M.lookup n env of
    Nothing -> do recordError $ "unbound variable: " ++ show n
                  newType
    Just (Forall as t) -> do ats <- forM as $ \a ->
                               do t' <- newType
                                  return (BoundVar a,t')
                             let s = listSubst ats
                             return $ appSubst s t

freeVarsInEnv :: TI (S.Set TyVar)
freeVarsInEnv = do
  env <- TI $ asks typeEnv
  let ss = M.elems env
  ss' <- mapM appSubstM ss
  return $ freeVars ss'

-- }}}

-- AppSubst {{{

class AppSubst t where
  appSubst :: Subst -> t -> t

instance (AppSubst t) => AppSubst [t] where
  appSubst s = map $ appSubst s

instance (AppSubst t) => AppSubst (Maybe t) where
  appSubst s = fmap $ appSubst s

instance AppSubst Type where
  appSubst s t = case t of
    TyCon tc ts -> TyCon tc $ appSubst s ts
    TyRecord fs -> TyRecord $ appSubst s fs
    TyVar tv    -> case M.lookup tv $ unSubst s of
                     Just t' -> t'
                     Nothing -> t

instance AppSubst Schema where
  appSubst s (Forall ns t) = Forall ns $ appSubst s t

instance AppSubst Expr where
  appSubst s expr = case expr of
    TSig e t           -> TSig (appSubst s e) (appSubst s t)

    Bit b              -> Bit b
    String str         -> String str
    Z i                -> Z i
    Undefined          -> Undefined
    Code _             -> expr
    Array es           -> Array $ appSubst s es
    Block bs           -> Block $ appSubst s bs
    Tuple es           -> Tuple $ appSubst s es
    Record fs          -> Record $ appSubst s fs
    Index ar ix        -> Index (appSubst s ar) (appSubst s ix)
    Lookup rec fld     -> Lookup (appSubst s rec) fld
    TLookup tpl idx    -> TLookup (appSubst s tpl) idx
    Var x              -> Var x
    Function x xt body -> Function x (appSubst s xt) (appSubst s body)
    Application f v    -> Application (appSubst s f) (appSubst s v)
    Let ds e           -> Let (appSubst s ds) (appSubst s e)

instance (Ord k, AppSubst a) => AppSubst (M.Map k a) where
  appSubst s = fmap (appSubst s)

instance AppSubst BlockStmt where
  appSubst s bst = case bst of
    Bind mn mt ctx e -> Bind mn mt ctx e
    BlockLet ds   -> BlockLet (appSubst s ds)
    BlockCode str -> BlockCode str

instance AppSubst Decl where
  appSubst s (Decl n mt e) = Decl n (appSubst s mt) (appSubst s e)

-- }}}

-- Instantiate {{{

class Instantiate t where
  instantiate :: [(Name,Type)] -> t -> t

instance (Instantiate a) => Instantiate (Maybe a) where
  instantiate nts = fmap $ instantiate nts

instance (Instantiate a) => Instantiate [a] where
  instantiate nts = map $ instantiate nts

instance Instantiate Type where
  instantiate nts typ = case typ of
    TyCon tc ts -> TyCon tc $ instantiate nts ts
    TyRecord fs -> TyRecord $ fmap (instantiate nts) fs
    TyVar (BoundVar n) -> maybe typ id $ lookup n nts
    _ -> typ

-- }}}

-- Type Inference {{{

type OutExpr      = Expr
type OutBlockStmt = BlockStmt


inferE :: (LName, Expr) -> TI (OutExpr,Type)
inferE (ln, expr) = case expr of
  Bit b     -> return (Bit b, tBool)
  String s  -> return (String s, tString)
  Z i       -> return (Z i, tZ)
  Undefined -> do a <- newType
                  return (Undefined, a)
  Code s    -> return (Code s, tTerm)

  Array  [] -> do a <- newType
                  return (Array [], tArray a)

  Array (e:es) -> do (e',t) <- inferE (ln, e)
                     es' <- mapM (flip (checkE ln) t) es
                     return (Array (e':es'), tArray t)

  Block bs -> do ctx <- newType
                 (bs',t') <- inferStmts ln ctx bs
                 return (Block bs', tBlock ctx t')

  Tuple  es -> do (es',ts) <- unzip `fmap` mapM (inferE . (ln,)) es
                  return (Tuple es', tTuple ts)

  Record fs -> do (nes',nts) <- unzip `fmap` mapM (inferField ln) (M.toList fs)
                  return (Record (M.fromList nes'), TyRecord $ M.fromList nts)

  Index ar ix -> do (ar',at) <- inferE (ln,ar)
                    ix'      <- checkE ln ix tZ
                    t        <- newType
                    unify ln (tArray t) at
                    return (Index ar' ix', t)

  TSig e t  -> do t' <- checkKind t
                  (e',t'') <- inferE (ln,e)
                  unify ln t' t''
                  return (e',t'')
  {-
  TSig e (Forall [] t) -> do t' <- checkKind t
                             e' <- checkE e t'
                             return (e', t')

  TSig e (Forall _ _) -> do recordError "TODO: TSig with Schema"
                            inferE e
  -}


  Function x mt body -> do xt <- maybe newType return mt
                           (body',t) <- bindLocalSchemas [(x,tMono xt)] $
                                          inferE (ln,body)
                           return (Function x (Just xt) body', tFun xt t)

  Application f v -> do (v',fv) <- inferE (ln,v)
                        t <- newType
                        let ft = tFun fv t
                        f' <- checkE ln f ft
                        return (Application f' v', t)

  Var x   -> do env <- TI $ asks typeEnv
                case M.lookup x env of
                  Nothing -> do
                    recordError $ "unbound variable: " ++ show x
                    t <- newType
                    return (Var x, t)
                  Just (Forall as t) -> do
                    ts <- mapM (const newType) as
                    return (Var x, instantiate (zip as ts) t)

  Let bs body -> inferDecls bs $ \bs' -> do
                   (body',t) <- inferE (ln, body)
                   return (Let bs' body', t)

  Lookup e n ->
    do (e1,t) <- inferE (ln, e)
       t1 <- appSubstM t
       elTy <- case t1 of
                 TyRecord fs
                    | Just ty <- M.lookup n fs -> return ty
                    | otherwise ->
                          do recordError $ unlines
                                [ "Selecting a missing field."
                                , "Field name: " ++ n
                                ]
                             newType
                 _ -> do recordError $ unlines
                            [ "We only support simple record lookup for now."
                            , "Please add type signature on argument."
                            ]
                         newType
       return (Lookup e1 n, elTy)
  TLookup e i ->
    do (e1,t) <- inferE (ln,e)
       t1 <- appSubstM t
       elTy <- case t1 of
                 TyCon (TupleCon n) tys
                   | i <= n -> return (tys !! (fromIntegral i - 1))
                   | otherwise ->
                          do recordError $ unlines
                                [ "Tuple index out of bounds."
                                , "Given index " ++ show i ++
                                  " is greater than tuple size of " ++
                                  show n
                                ]
                             newType
                 _ -> do recordError $ unlines
                            [ "We only support simple tuple lookup for now."
                            , "Please add type signature on argument."
                            ]
                         newType
       return (TLookup e1 i, elTy)



checkE :: LName -> Expr -> Type -> TI OutExpr
checkE m e t = do
  (e',t') <- inferE (m,e)
  unify m t t'
  return e'

inferField :: LName -> Bind Expr -> TI (Bind OutExpr,Bind Type)
inferField m (n,e) = do
  (e',t) <- inferE (m,e)
  return ((n,e'),(n,t))

inferDecls :: [Decl] -> ([Decl] -> TI a) -> TI a
inferDecls ds nextF = do
  ds' <- mapM inferDecl ds
  bindDecls ds' (nextF ds')

inferStmts :: LName -> Type -> [BlockStmt] -> TI ([OutBlockStmt],Type)

inferStmts m _ctx [] = do
  recordError ("do block must include at least one expression at " ++ show m)
  t <- newType
  return ([], t)

inferStmts m ctx [Bind Nothing _ mc e] = do
  t  <- newType
  e' <- checkE m e (tBlock ctx t)
  mc' <- case mc of
    Nothing -> return ctx
    Just ty  -> do ty' <- checkKind ty
                   unify m ty ctx -- TODO: should this be ty'?
                   return ty'
  return ([Bind Nothing (Just t) (Just mc') e'],t)

inferStmts m _ [_] = do
  recordError ("do block must end with expression at " ++ show m)
  t <- newType
  return ([],t)

inferStmts m ctx (Bind mn mt mc e : more) = do
  t <- maybe newType return mt
  e' <- checkE m e (tBlock ctx t)
  mc' <- case mc of
    Nothing -> return ctx
    Just c  -> do c' <- checkKind c
                  unify m c ctx
                  return c'
  let f = case mn of
        Nothing -> id
        Just n  -> bindSchema n (tMono t)
  (more',t') <- f $ inferStmts m ctx more

  return (Bind mn (Just t') (Just mc') e' : more', t')

inferStmts m ctx (BlockLet bs : more) = inferDecls bs $ \bs' -> do
  (more',t) <- inferStmts m ctx more
  return (BlockLet bs' : more', t)

inferStmts m ctx (BlockCode s : more) = do
  (more',t) <- inferStmts m ctx more
  return (BlockCode s : more', t)

-- | FIXME: If the Decl has a schema annotation, then match it against
-- the inferred type afterwards.
inferDecl :: Decl -> TI Decl
inferDecl (Decl n _ e) = do
  (e',t) <- inferE (n, e)
  [(e1,s)] <- generalize [e'] [t]
  return (Decl n (Just s) e1)


-- XXX: For now, no schema type signatures.
inferRecDecls :: [Decl] -> TI [Decl]
inferRecDecls ds =
  do let names = map dName ds
     guessedTypes <- mapM (\_ -> newType) ds
     (es,ts) <- unzip `fmap`
                bindTopSchemas (zip names (map tMono guessedTypes))
                               (mapM inferE [ (n, e) | Decl n _ e <- ds ])
     _ <- sequence $ zipWith3 unify names ts guessedTypes
     (es1,ss) <- unzip `fmap` generalize es ts
     return [ Decl n (Just s) e | (n, s, e) <- zip3 names ss es1 ]


generalize :: [OutExpr] -> [Type] -> TI [(OutExpr,Schema)]
generalize es0 ts0 =
  do ts <- appSubstM ts0
     es <- appSubstM es0

     let cs = freeVars ts
     withAsmps <- freeVarsInEnv
     let (ns,gvs) = unzip $ mapMaybe toBound $ S.toList $ cs S.\\ withAsmps
     let s = listSubst gvs
         mk e t = (appSubst s e, Forall ns (appSubst s t))

     return $ zipWith mk es ts

  where
  toBound :: TyVar -> Maybe (Name,(TyVar,Type))
  toBound v@(FreeVar i) = let nm = "a." ++ show i in
                                Just (nm,(v,TyVar (BoundVar nm)))
  toBound _ = Nothing

-- Check a list of recursive groups, sorted by dependency.
inferTopDecls :: [[Decl]] -> TI [[Decl]]
inferTopDecls [] = return []
inferTopDecls (ds : dss) =
  do ds1 <- inferRecDecls ds
     rest <- bindDecls ds1 (inferTopDecls dss)
     return (ds1 : rest)


-- Compute groups of recursive components
computeSCCGroups :: A.ModuleName -> [Decl] -> [[Decl]]
computeSCCGroups _ = map (: [])
-- ^ FIXME: remove

-- XXX: TODO
checkKind :: Type -> TI Type
checkKind = return



-- }}}

-- Main interface {{{

checkModule :: Compiler Module Module
checkModule {- initTs -} = compiler "TypeCheck" $ \m -> do
  let modName = moduleName m
  let decls   = moduleExprEnv m
  let initTs  = concat
       [ [ (n, s) | (Decl n (Just s) _) <- modExprs dep ] ++ modPrims dep
       | (_mn,dep) <- depMods m
       ]
  let (primTs,prims) = unzip [ ((n, t), (n, t))
                             | (n, t) <- modPrims m ]
  let sccs = computeSCCGroups modName decls
  let go = bindSchemas (initTs ++ primTs) ((,) <$> (inferTopDecls sccs >>= exportDecls) <*> pure (M.fromList prims) )
  case evalTI (moduleName m) go of
    Right (exprRes,primRes) -> return $ m { moduleExprEnv = exprRes , modulePrimEnv = primRes }
    Left errs               -> fail $ unlines errs
  where
  depMods = M.toList . moduleDependencies
  modExprs = moduleExprEnv
  modPrims = M.toList . modulePrimEnv

  exportDecls dss = sequence [ appSubstM d | ds <- dss, d <- ds ]

evalTI :: ModuleName -> TI a -> Either [String] a
evalTI mn m = case runTI mn m of
  (res,_,[]) -> Right res
  (_,_,errs) -> Left errs

runTI :: ModuleName -> TI a -> (a,Subst,[String])
runTI mn m = (a,subst rw, errors rw)
  where
  m' = runReaderT (unTI m) (emptyRO mn)
  (a,rw) = runState m' emptyRW

-- }}}
