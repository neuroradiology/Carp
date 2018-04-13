module InitialTypes where

import Control.Monad.State
import qualified Data.Map as Map

import Types
import Obj
import Util
import TypeError
import Lookup

-- | Create a fresh type variable (eg. 'VarTy t0', 'VarTy t1', etc...)
genVarTyWithPrefix :: String -> State Integer Ty
genVarTyWithPrefix prefix =
  do x <- get
     put (x + 1)
     return (VarTy (prefix ++ show x))

genVarTy :: State Integer Ty
genVarTy = genVarTyWithPrefix "t"

-- | Create a list of type variables with increasing names
genVarTys :: Int -> State Integer [Ty]
genVarTys n = replicateM n genVarTy

-- | Gives all type variables new names ("t<n>", counting from current state) while
--   still preserving the same name for type variables with a shared name.
--   Example: (t0, t1, t1) -> t0
--   becomes: (r2, r3, r3) -> r2
renameVarTys :: Ty -> State Integer Ty
renameVarTys rootType = do n <- get
                           let (result, (n', _)) = runState (rename rootType) (n, Map.empty)
                           put n'
                           return result
  where
    rename :: Ty -> State (Integer, Map.Map String Ty) Ty
    rename (FuncTy argTys retTy) = do argTys' <- mapM rename argTys
                                      retTy' <- rename retTy
                                      return (FuncTy argTys' retTy')
    rename (VarTy v) = do (n, mappings) <- get
                          case Map.lookup v mappings of
                            Just found -> return found
                            Nothing -> do let varTy = VarTy ("r" ++ show n)
                                              newMappings = Map.insert v varTy mappings
                                          put (n + 1, newMappings)
                                          return varTy
    rename (StructTy name tyArgs) = do tyArgs' <- mapM rename tyArgs
                                       return (StructTy name tyArgs')

    rename (PointerTy x) = do x' <- rename x
                              return (PointerTy x')

    rename (RefTy x) = do x' <- rename x
                          return (RefTy x')

    rename x = return x

-- | Adds initial types to a s-expression and all its sub-nodes.
-- | Example: (f 10) => <(<f : (Fn [Int] Bool>) <10 : Int>) : t0>
initialTypes :: TypeEnv -> Env -> XObj -> Either TypeError XObj
initialTypes typeEnv rootEnv root = evalState (visit rootEnv root) 0
  where
    visit :: Env -> XObj -> State Integer (Either TypeError XObj)
    visit env xobj = case obj xobj of
                       (Num t _)          -> return (Right (xobj { ty = Just t }))
                       (Bol _)            -> return (Right (xobj { ty = Just BoolTy }))
                       (Str _)            -> return (Right (xobj { ty = Just (RefTy StringTy) }))
                       (Pattern _)          -> return (Right (xobj { ty = Just (RefTy PatternTy) }))
                       (Chr _)            -> return (Right (xobj { ty = Just CharTy }))
                       Break              -> return (Right (xobj { ty = Just (FuncTy [] UnitTy)}))
                       (Lst _)            -> visitList env xobj
                       (Arr _)            -> visitArray env xobj
                       (Sym symPath _)    -> visitSymbol env xobj symPath
                       (MultiSym _ paths) -> visitMultiSym env xobj paths
                       (InterfaceSym _)   -> visitInterfaceSym env xobj
                       Defn               -> return (Left (InvalidObj Defn xobj))
                       Def                -> return (Left (InvalidObj Def xobj))
                       Let                -> return (Left (InvalidObj Let xobj))
                       If                 -> return (Left (InvalidObj If xobj))
                       And                 -> return (Left (InvalidObj And xobj))
                       Or                 -> return (Left (InvalidObj Or xobj))
                       While              -> return (Left (InvalidObj While xobj))
                       Do                 -> return (Left (InvalidObj Do xobj))
                       (Mod _)            -> return (Left (InvalidObj If xobj))
                       e@(Typ _)          -> return (Left (InvalidObj e xobj))
                       e@(External _)     -> return (Left (InvalidObj e xobj))
                       ExternalType       -> return (Left (InvalidObj ExternalType xobj))
                       e@(Deftemplate _)  -> return (Left (InvalidObj e xobj))
                       e@(Instantiate _)  -> return (Left (InvalidObj e xobj))
                       e@(Defalias _)     -> return (Left (InvalidObj e xobj))
                       Address            -> return (Left (InvalidObj Address xobj))
                       SetBang            -> return (Left (InvalidObj SetBang xobj))
                       Macro              -> return (Left (InvalidObj Macro xobj))
                       The                -> return (Left (InvalidObj The xobj))
                       Dynamic            -> return (Left (InvalidObj Dynamic xobj))
                       Ref                -> return (Left (InvalidObj Ref xobj))
                       With               -> return (Left (InvalidObj With xobj))

    visitSymbol :: Env -> XObj -> SymPath -> State Integer (Either TypeError XObj)
    visitSymbol env xobj symPath =
      case symPath of
        -- Symbols with leading ? are 'holes'.
        SymPath _ name@('?' : _) -> return (Right (xobj { ty = Just (VarTy name) }))
        SymPath _ (':' : _) -> return (Left (LeadingColon xobj))
        _ ->
          case lookupInEnv symPath env of
            Just (foundEnv, binder) ->
              case ty (binderXObj binder) of
                -- Don't rename internal symbols like parameters etc!
                Just theType | envIsExternal foundEnv -> do renamed <- renameVarTys theType
                                                            return (Right (xobj { ty = Just renamed }))
                             | otherwise -> return (Right (xobj { ty = Just theType }))
                Nothing -> return (Left (SymbolMissingType xobj foundEnv))
            Nothing -> return (Left (SymbolNotDefined symPath xobj))

    visitMultiSym :: Env -> XObj -> [SymPath] -> State Integer (Either TypeError XObj)
    visitMultiSym _ xobj@(XObj (MultiSym name _) _ _) _ =
      do freshTy <- genVarTy
         return (Right xobj { ty = Just freshTy })

    visitInterfaceSym :: Env -> XObj -> State Integer (Either TypeError XObj)
    visitInterfaceSym env xobj@(XObj (InterfaceSym name) _ _) =
      do freshTy <- case lookupInEnv (SymPath [] name) (getTypeEnv typeEnv) of
                      Just (_, Binder _ (XObj (Lst [XObj (Interface interfaceSignature _) _ _, _]) _ _)) -> renameVarTys interfaceSignature
                      Just (_, Binder _ x) -> error ("A non-interface named '" ++ name ++ "' was found in the type environment: " ++ show x)
                      Nothing -> genVarTy
         return (Right xobj { ty = Just freshTy })

    visitArray :: Env -> XObj -> State Integer (Either TypeError XObj)
    visitArray env (XObj (Arr xobjs) i _) =
      do visited <- mapM (visit env) xobjs
         arrayVarTy <- genVarTy
         return $ do okVisited <- sequence visited
                     Right (XObj (Arr okVisited) i (Just (StructTy "Array" [arrayVarTy])))

    visitArray _ _ = error "The function 'visitArray' only accepts XObj:s with arrays in them."

    visitList :: Env -> XObj -> State Integer (Either TypeError XObj)
    visitList env xobj@(XObj (Lst xobjs) i _) =
      case xobjs of
        -- Defn
        [defn@(XObj Defn _ _), nameSymbol@(XObj (Sym (SymPath _ name) _) _ _), XObj (Arr argList) argsi argst, body] ->
          do argTypes <- genVarTys (length argList)
             returnType <- genVarTy
             funcScopeEnv <- extendEnvWithParamList env argList
             let funcTy = Just (FuncTy argTypes returnType)
                 typedNameSymbol = nameSymbol { ty = funcTy }
                 -- This environment binding is for self-recursion, allows lookup of the symbol:
                 envWithSelf = extendEnv funcScopeEnv name typedNameSymbol
             visitedBody <- visit envWithSelf body
             visitedArgs <- mapM (visit envWithSelf) argList
             return $ do okBody <- visitedBody
                         okArgs <- sequence visitedArgs
                         return (XObj (Lst [defn, nameSymbol, XObj (Arr okArgs) argsi argst, okBody]) i funcTy)

        [XObj Defn _ _, XObj (Sym _ _) _ _, XObj (Arr _) _ _] -> return (Left (NoFormsInBody xobj))
        XObj Defn _ _ : _  -> return (Left (InvalidObj Defn xobj))

        -- Def
        [def@(XObj Def _ _), nameSymbol, expression]->
          do definitionType <- genVarTy
             visitedExpr <- visit env expression
             return $ do okExpr <- visitedExpr
                         return (XObj (Lst [def, nameSymbol, okExpr]) i (Just definitionType))

        XObj Def _ _ : _ -> return (Left (InvalidObj Def xobj))

        -- Let binding
        [letExpr@(XObj Let _ _), XObj (Arr bindings) bindi bindt, body] ->
          do wholeExprType <- genVarTy
             letScopeEnv <- extendEnvWithLetBindings env bindings
             case letScopeEnv of
               Right okLetScopeEnv ->
                 do visitedBindings <- mapM (visit okLetScopeEnv) bindings
                    visitedBody <- visit okLetScopeEnv body
                    return $ do okBindings <- sequence visitedBindings
                                okBody <- visitedBody
                                return (XObj (Lst [letExpr, XObj (Arr okBindings) bindi bindt, okBody]) i (Just wholeExprType))
               Left err -> return (Left err)

        [XObj Let _ _, XObj (Arr _) _ _] ->
          return (Left (NoFormsInBody xobj))
        XObj Let _ _ : XObj (Arr _) _ _ : _ ->
          return (Left (TooManyFormsInBody xobj))
        XObj Let _ _ : _ ->
          return (Left (InvalidObj Let xobj))

        -- If
        [ifExpr@(XObj If _ _), expr, ifTrue, ifFalse] ->
          do visitedExpr <- visit env expr
             visitedTrue <- visit env ifTrue
             visitedFalse <- visit env ifFalse
             returnType <- genVarTy
             return $ do okExpr <- visitedExpr
                         okTrue <- visitedTrue
                         okFalse <- visitedFalse
                         return (XObj (Lst [ifExpr
                                           ,okExpr
                                           ,okTrue
                                           ,okFalse
                                           ]) i (Just returnType))

        XObj If _ _ : _ -> return (Left (InvalidObj If xobj))

        -- While (always return Unit)
        [whileExpr@(XObj While _ _), expr, body] ->
          do visitedExpr <- visit env expr
             visitedBody <- visit env body
             return $ do okExpr <- visitedExpr
                         okBody <- visitedBody
                         return (XObj (Lst [whileExpr, okExpr, okBody]) i (Just UnitTy))

        [XObj While _ _, _] ->
          return (Left (NoFormsInBody xobj))
        XObj While _ _ : _ ->
          return (Left (TooManyFormsInBody xobj))

        -- Do
        doExpr@(XObj Do _ _) : expressions ->
          do t <- genVarTy
             visitedExpressions <- fmap sequence (mapM (visit env) expressions)
             return $ do okExpressions <- visitedExpressions
                         return (XObj (Lst (doExpr : okExpressions)) i (Just t))

        -- Address
        [addressExpr@(XObj Address _ _), value] ->
          do visitedValue <- visit env value
             return $ do okValue <- visitedValue
                         let Just t' = ty okValue
                         return (XObj (Lst [addressExpr, okValue]) i (Just (PointerTy t')))

        -- Set!
        [setExpr@(XObj SetBang _ _), variable, value] ->
          do visitedVariable <- visit env variable
             visitedValue <- visit env value
             return $ do okVariable <- visitedVariable
                         okValue <- visitedValue
                         return (XObj (Lst [setExpr, okVariable, okValue]) i (Just UnitTy))
        XObj SetBang _ _ : _ -> return (Left (InvalidObj SetBang xobj))

        -- The
        [theExpr@(XObj The _ _), typeXObj, value] ->
          do visitedValue <- visit env value
             return $ do okValue <- visitedValue
                         case xobjToTy typeXObj of
                           Just okType -> return (XObj (Lst [theExpr, typeXObj, okValue]) i (Just okType))
                           Nothing -> Left (NotAType typeXObj)
        XObj The _ _ : _ -> return (Left (InvalidObj The xobj))

        -- Ref
        [refExpr@(XObj Ref _ _), value] ->
          do visitedValue <- visit env value
             return $ do okValue <- visitedValue
                         let Just valueTy = ty okValue
                         return (XObj (Lst [refExpr, okValue]) i (Just (RefTy valueTy)))

        -- And
        [andExpr@(XObj And _ _), expr1, expr2] ->
          do visitedExpr1 <- visit env expr1
             visitedExpr2 <- visit env expr2
             return $ do okExpr1 <- visitedExpr1
                         okExpr2 <- visitedExpr2
                         return (XObj (Lst [andExpr, okExpr1, okExpr2]) i (Just BoolTy))

        -- Or
        [orExpr@(XObj Or _ _), expr1, expr2] ->
          do visitedExpr1 <- visit env expr1
             visitedExpr2 <- visit env expr2
             return $ do okExpr1 <- visitedExpr1
                         okExpr2 <- visitedExpr2
                         return (XObj (Lst [orExpr, okExpr1, okExpr2]) i (Just BoolTy))

        -- Function application
        func : args ->
          do t <- genVarTy
             visitedFunc <- visit env func
             visitedArgs <- fmap sequence (mapM (visit env) args)
             return $ do okFunc <- visitedFunc
                         okArgs <- visitedArgs
                         return (XObj (Lst (okFunc : okArgs)) i (Just t))

        -- Empty list
        [] -> return (Right xobj { ty = Just UnitTy })

    visitList _ _ = error "Must match on list!"

    extendEnvWithLetBindings :: Env -> [XObj] -> State Integer (Either TypeError Env)
    extendEnvWithLetBindings env xobjs =
      let pairs = pairwise xobjs
          emptyInnerEnv = Env { envBindings = Map.fromList []
                              , envParent = Just env
                              , envModuleName = Nothing
                              , envUseModules = []
                              , envMode = InternalEnv
                              }
      -- Need to fold (rather than map) to make the previous bindings accesible to the later ones, i.e. (let [a 100 b a] ...)
      in  foldM createBinderForLetPair (Right emptyInnerEnv) pairs
      where
        createBinderForLetPair :: Either TypeError Env -> (XObj, XObj) -> State Integer (Either TypeError Env)
        createBinderForLetPair envOrErr (sym, expr) =
          case envOrErr of
            Left err -> return (Left err)
            Right env' ->
              case obj sym of
                (Sym (SymPath _ name) _) -> do visited <- visit env' expr
                                               return $ do okVisited <- visited
                                                           return (envAddBinding env' name (Binder emptyMeta okVisited))
                _ -> error ("Can't create let-binder for non-symbol: " ++ show sym)

    extendEnvWithParamList :: Env -> [XObj] -> State Integer Env
    extendEnvWithParamList env xobjs =
      do binders <- mapM createBinderForParam xobjs
         return Env { envBindings = Map.fromList binders
                    , envParent = Just env
                    , envModuleName = Nothing
                    , envUseModules = []
                    , envMode = InternalEnv
                    }
      where
        createBinderForParam :: XObj -> State Integer (String, Binder)
        createBinderForParam xobj =
          case obj xobj of
            (Sym (SymPath _ name) _) ->
              do t <- genVarTy
                 let xobjWithTy = xobj { ty = Just t }
                 return (name, Binder emptyMeta xobjWithTy)
            _ -> error "Can't create binder for non-symbol parameter."
