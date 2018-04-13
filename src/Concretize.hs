module Concretize where

import Control.Monad.State
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Set ((\\))
import Data.List (foldl')
import Debug.Trace

import Obj
import Constraints
import Types
import Util
import TypeError
import AssignTypes
import Polymorphism
import InitialTypes
import Lookup

-- | This function performs two things:
-- |  1. Finds out which polymorphic functions that needs to be added to the environment for the calls in the function to work.
-- |  2. Changes the name of symbols at call sites so they use the polymorphic name
-- |  Both of these results are returned in a tuple: (<new xobj>, <dependencies>)
concretizeXObj :: Bool -> TypeEnv -> Env -> [SymPath] -> XObj -> Either TypeError (XObj, [XObj])
concretizeXObj allowAmbiguityRoot typeEnv rootEnv visitedDefinitions root =
  case runState (visit allowAmbiguityRoot rootEnv root) [] of
    (Left err, _) -> Left err
    (Right xobj, deps) -> Right (xobj, deps)
  where
    visit :: Bool -> Env -> XObj -> State [XObj] (Either TypeError XObj)
    visit allowAmbig env xobj@(XObj (Sym _ _) _ _) = visitSymbol allowAmbig env xobj
    visit allowAmbig env xobj@(XObj (MultiSym _ _) _ _) = visitMultiSym allowAmbig env xobj
    visit allowAmbig env xobj@(XObj (InterfaceSym _) _ _) = visitInterfaceSym allowAmbig env xobj
    visit allowAmbig env xobj@(XObj (Lst _) i t) =
      do visited <- visitList allowAmbig env xobj
         return $ do okVisited <- visited
                     Right (XObj (Lst okVisited) i t)
    visit allowAmbig env xobj@(XObj (Arr arr) i (Just t)) =
      do visited <- fmap sequence (mapM (visit allowAmbig env) arr)
         concretizeTypeOfXObj typeEnv xobj
         return $ do okVisited <- visited
                     Right (XObj (Arr okVisited) i (Just t))
    visit _ _ x = return (Right x)

    visitList :: Bool -> Env -> XObj -> State [XObj] (Either TypeError [XObj])
    visitList _ _ (XObj (Lst []) _ _) = return (Right [])

    visitList _ env (XObj (Lst [defn@(XObj Defn _ _), nameSymbol@(XObj (Sym (SymPath [] "main") _) _ _), args@(XObj (Arr argsArr) _ _), body]) _ _) =
      if not (null argsArr)
      then return $ Left (MainCannotHaveArguments nameSymbol (length argsArr))
      else do visitedBody <- visit False env body -- allowAmbig == 'False'
              return $ do okBody <- visitedBody
                          let t = fromMaybe UnitTy (ty okBody)
                          if t /= UnitTy && t /= IntTy
                          then Left (MainCanOnlyReturnUnitOrInt nameSymbol t)
                          else return [defn, nameSymbol, args, okBody]

    visitList _ env (XObj (Lst [defn@(XObj Defn _ _), nameSymbol, args@(XObj (Arr argsArr) _ _), body]) _ t) =
      do mapM_ (concretizeTypeOfXObj typeEnv) argsArr
         let functionEnv = Env Map.empty (Just env) Nothing [] InternalEnv
             envWithArgs = foldl' (\e arg@(XObj (Sym (SymPath _ argSymName) _) _ _) ->
                                     extendEnv e argSymName arg)
                                  functionEnv argsArr
             Just funcTy = t
             allowAmbig = isTypeGeneric funcTy
         visitedBody <- visit allowAmbig envWithArgs body
         return $ do okBody <- visitedBody
                     return [defn, nameSymbol, args, okBody]

    visitList allowAmbig env (XObj (Lst [letExpr@(XObj Let _ _), XObj (Arr bindings) bindi bindt, body]) _ _) =
      do visitedBindings <- fmap sequence (mapM (visit allowAmbig env) bindings)
         visitedBody <- visit allowAmbig env body
         mapM_ (concretizeTypeOfXObj typeEnv) (map fst (pairwise bindings))
         return $ do okVisitedBindings <- visitedBindings
                     okVisitedBody <- visitedBody
                     return [letExpr, XObj (Arr okVisitedBindings) bindi bindt, okVisitedBody]

    visitList allowAmbig env (XObj (Lst [theExpr@(XObj The _ _), typeXObj, value]) _ _) =
      do visitedValue <- visit allowAmbig env value
         return $ do okVisitedValue <- visitedValue
                     return [theExpr, typeXObj, okVisitedValue]

    visitList allowAmbig env (XObj (Lst [andExpr@(XObj And _ _), expr1, expr2]) _ _) =
      do visitedExpr1 <- visit allowAmbig env expr1
         visitedExpr2 <- visit allowAmbig env expr2
         return $ do okVisitedExpr1 <- visitedExpr1
                     okVisitedExpr2 <- visitedExpr2
                     return [andExpr, okVisitedExpr1, okVisitedExpr2]

    visitList allowAmbig env (XObj (Lst [orExpr@(XObj Or _ _), expr1, expr2]) _ _) =
      do visitedExpr1 <- visit allowAmbig env expr1
         visitedExpr2 <- visit allowAmbig env expr2
         return $ do okVisitedExpr1 <- visitedExpr1
                     okVisitedExpr2 <- visitedExpr2
                     return [orExpr, okVisitedExpr1, okVisitedExpr2]

    visitList allowAmbig env (XObj (Lst (func : args)) _ _) =
      do concretizeTypeOfXObj typeEnv func
         mapM_ (concretizeTypeOfXObj typeEnv) args
         f <- visit allowAmbig env func
         a <- fmap sequence (mapM (visit allowAmbig env) args)
         return $ do okF <- f
                     okA <- a
                     return (okF : okA)

    visitSymbol :: Bool -> Env -> XObj -> State [XObj] (Either TypeError XObj)
    visitSymbol allowAmbig env xobj@(XObj (Sym path lookupMode) i t) =
      case lookupInEnv path env of
        Just (foundEnv, binder)
          | envIsExternal foundEnv ->
            let theXObj = binderXObj binder
                Just theType = ty theXObj
                typeOfVisited = case t of
                                  Just something -> something
                                  Nothing -> error ("Missing type on " ++ show xobj ++ " at " ++ prettyInfoFromXObj xobj)
            in if --(trace $ "CHECKING " ++ getName xobj ++ " : " ++ show theType ++ " with visited type " ++ show typeOfVisited ++ " and visited definitions: " ++ show visitedDefinitions) $
                  isTypeGeneric theType && not (isTypeGeneric typeOfVisited)
                  then case concretizeDefinition allowAmbig typeEnv env visitedDefinitions theXObj typeOfVisited of
                         Left err -> return (Left err)
                         Right (concrete, deps) ->
                           do modify (concrete :)
                              modify (deps ++)
                              return (Right (XObj (Sym (getPath concrete) lookupMode) i t))
                  else return (Right xobj)
          | otherwise -> return (Right xobj)
        Nothing -> return (Right xobj)
    visitSymbol _ _ _ = error "Not a symbol."

    visitMultiSym :: Bool -> Env -> XObj -> State [XObj] (Either TypeError XObj)
    visitMultiSym allowAmbig env xobj@(XObj (MultiSym originalSymbolName paths) i t) =
      let Just actualType = t
          tys = map (typeFromPath env) paths
          tysToPathsDict = zip tys paths
      in  case filter (matchingSignature actualType) tysToPathsDict of
            [] ->
              --if allowAmbiguity
              --then return (Right xobj)
              --else
              return (Left (NoMatchingSignature xobj originalSymbolName actualType tysToPathsDict))
            [(theType, singlePath)] -> let Just t' = t
                                           fake1 = XObj (Sym (SymPath [] "theType") Symbol) Nothing Nothing
                                           fake2 = XObj (Sym (SymPath [] "xobjType") Symbol) Nothing Nothing
                                           Just i' = i
                                       in  case solve [Constraint theType t' fake1 fake2 OrdMultiSym] of
                                             Right mappings ->
                                               let replaced = replaceTyVars mappings t'
                                                   suffixed = suffixTyVars ("_x" ++ show (infoIdentifier i')) replaced -- Make sure it gets unique type variables. TODO: Is there a better way?
                                                   normalSymbol = XObj (Sym singlePath LookupGlobal) i (Just suffixed)
                                               in visitSymbol allowAmbig env $ --(trace ("Disambiguated " ++ pretty xobj ++ " at " ++ prettyInfoFromXObj xobj ++ " to " ++ show singlePath ++ " : " ++ show suffixed ++ ", used to be " ++ show t' ++ ", theType = " ++ show theType ++ ", mappings = " ++ show mappings))
                                                              normalSymbol
                                             Left failure@(UnificationFailure _ _) ->
                                               return $ Left (UnificationFailed
                                                              (unificationFailure failure)
                                                              (unificationMappings failure)
                                                              [])
                                             Left (Holes holes) ->
                                               return $ Left (HolesFound holes)
            severalPaths -> return (Right xobj)
                            -- if allowAmbig
                            -- then
                            -- else return (Left (CantDisambiguate xobj originalSymbolName actualType severalPaths))

    visitMultiSym _ _ _ = error "Not a multi symbol."

    visitInterfaceSym :: Bool -> Env -> XObj -> State [XObj] (Either TypeError XObj)
    visitInterfaceSym allowAmbig env xobj@(XObj (InterfaceSym name) i t) =
      case lookupInEnv (SymPath [] name) (getTypeEnv typeEnv) of
        Just (_, Binder _ (XObj (Lst [XObj (Interface interfaceSignature interfacePaths) _ _, _]) _ _)) ->
          let Just actualType = t
              tys = map (typeFromPath env) interfacePaths
              tysToPathsDict = zip tys interfacePaths
          in  case filter (matchingSignature actualType) tysToPathsDict of
                [] -> return $ -- (trace ("No matching signatures for interface lookup of " ++ name ++ " of type " ++ show actualType ++ " " ++ prettyInfoFromXObj xobj ++ ", options are:\n" ++ joinWith "\n" (map show tysToPathsDict))) $
                               --(Right xobj)
                                 if allowAmbig
                                 then (Right xobj) -- No exact match of types
                                 else (Left (NoMatchingSignature xobj name actualType tysToPathsDict))
                [(theType, singlePath)] ->
                  replace theType singlePath
                severalPaths ->
                    --(trace ("Several matching signatures for interface lookup of '" ++ name ++ "' of type " ++ show actualType ++ " " ++ prettyInfoFromXObj xobj ++ ", options are:\n" ++ joinWith "\n" (map show tysToPathsDict) ++ "\n  Filtered paths are:\n" ++ (joinWith "\n" (map show severalPaths)))) $
                    --(Left (CantDisambiguateInterfaceLookup xobj name interfaceType severalPaths)) -- TODO unnecessary error?
                    case filter (\(tt, _) -> actualType == tt) severalPaths of
                      []      -> return (Right xobj) -- No exact match of types
                      [(theType, singlePath)] -> replace theType singlePath -- Found an exact match, will ignore any "half matched" functions that might have slipped in.
                      _       -> return (Left (SeveralExactMatches xobj name actualType severalPaths))
              where replace theType singlePath =
                      let normalSymbol = XObj (Sym singlePath LookupGlobal) i t
                      in visitSymbol allowAmbig env $ --(trace ("Disambiguated interface symbol " ++ pretty xobj ++ prettyInfoFromXObj xobj ++ " to " ++ show singlePath ++ " : " ++ show t))
                                             normalSymbol

        Nothing ->
          error ("No interface named '" ++ name ++ "' found.")

-- | Do the signatures match?
matchingSignature :: Ty -> (Ty, SymPath) -> Bool
matchingSignature tA (tB, _) = areUnifiable tA tB

-- | Does the type of an XObj require additional concretization of generic types or some typedefs for function types, etc?
-- | If so, perform the concretization and append the results to the list of dependencies.
concretizeTypeOfXObj :: TypeEnv -> XObj -> State [XObj] (Either TypeError ())
concretizeTypeOfXObj typeEnv (XObj _ _ (Just t)) =
  case concretizeType typeEnv t of
    Right t -> do modify (t ++)
                  return (Right ())
    Left err -> return (Left (InvalidMemberType err))
concretizeTypeOfXObj _ xobj = return (Right ()) --error ("Missing type: " ++ show xobj)

-- | Find all the concrete deps of a type.
concretizeType :: TypeEnv -> Ty -> Either String [XObj]
concretizeType _ ft@(FuncTy _ _) =
  if isTypeGeneric ft
  then Right []
  else Right [defineFunctionTypeAlias ft]
concretizeType typeEnv arrayTy@(StructTy "Array" varTys) =
  if isTypeGeneric arrayTy
  then Right []
  else do deps <- mapM (concretizeType typeEnv) varTys
          Right ([defineArrayTypeAlias arrayTy] ++ concat deps)
concretizeType typeEnv genericStructTy@(StructTy name _) =
  case lookupInEnv (SymPath [] name) (getTypeEnv typeEnv) of
    Just (_, Binder _ (XObj (Lst (XObj (Typ originalStructTy) _ _ : _ : rest)) _ _)) ->
      if isTypeGeneric originalStructTy
      then instantiateGenericStructType typeEnv originalStructTy genericStructTy rest
      else Right []
    Just (_, Binder _ (XObj (Lst (XObj ExternalType _ _ : _)) _ _)) ->
      Right []
    Just (_, Binder _ x) ->
      error ("Non-deftype found in type env: " ++ show x)
    Nothing ->
      error ("Can't find type " ++ show genericStructTy ++ " with name '" ++ name ++ "' in type env.")
concretizeType _ t =
    Right [] -- ignore all other types

-- | Given an generic struct type and a concrete version of it, generate all dependencies needed to use the concrete one.
instantiateGenericStructType :: TypeEnv -> Ty -> Ty -> [XObj] -> Either String [XObj]
instantiateGenericStructType typeEnv originalStructTy@(StructTy _ originalTyVars) genericStructTy membersXObjs =
  -- Turn (deftype (A a) [x a, y a]) into (deftype (A Int) [x Int, y Int])
  let fake1 = XObj (Sym (SymPath [] "a") Symbol) Nothing Nothing
      fake2 = XObj (Sym (SymPath [] "b") Symbol) Nothing Nothing
      XObj (Arr memberXObjs) _ _ = head membersXObjs
  in  case solve [Constraint originalStructTy genericStructTy fake1 fake2 OrdMultiSym] of
        Left e -> error (show e)
        Right mappings ->
          let concretelyTypedMembers = replaceGenericTypeSymbolsOnMembers mappings memberXObjs
          in  case validateMembers typeEnv originalTyVars concretelyTypedMembers of
                Left err -> Left err
                Right () ->
                  let deps = sequence (map (f typeEnv) (pairwise concretelyTypedMembers))
                  in case deps of
                       Left err -> Left err
                       Right okDeps ->
                         Right $ [ XObj (Lst (XObj (Typ genericStructTy) Nothing Nothing :
                                              XObj (Sym (SymPath [] (tyToC genericStructTy)) Symbol) Nothing Nothing :
                                              [(XObj (Arr concretelyTypedMembers) Nothing Nothing)])
                                        ) (Just dummyInfo) (Just TypeTy)
                                 ] ++ concat okDeps

f :: TypeEnv -> (XObj, XObj) -> Either String [XObj]
f typeEnv (_, tyXObj) =
  case (xobjToTy tyXObj) of
    Just okTy -> concretizeType typeEnv okTy
    Nothing -> error ("Failed to convert " ++ pretty tyXObj ++ "to a type.")

-- | Get the type of a symbol at a given path.
typeFromPath :: Env -> SymPath -> Ty
typeFromPath env p =
  case lookupInEnv p env of
    Just (e, Binder _ found)
      | envIsExternal e -> forceTy found
      | otherwise -> error "Local bindings shouldn't be ambiguous."
    Nothing -> error ("Couldn't find " ++ show p ++ " in env " ++ safeEnvModuleName env)

-- | Given a definition (def, defn, template, external) and
--   a concrete type (a type without any type variables)
--   this function returns a new definition with the concrete
--   types assigned, and a list of dependencies.
concretizeDefinition :: Bool -> TypeEnv -> Env -> [SymPath] -> XObj -> Ty -> Either TypeError (XObj, [XObj])
concretizeDefinition allowAmbiguity typeEnv globalEnv visitedDefinitions definition concreteType =
  let SymPath pathStrings name = getPath definition
      Just polyType = ty definition
      suffix = polymorphicSuffix polyType concreteType
      newPath = SymPath pathStrings (name ++ suffix)
  in
    case definition of
      XObj (Lst (XObj Defn _ _ : _)) _ _ ->
        let withNewPath = setPath definition newPath
            mappings = unifySignatures polyType concreteType
        in case assignTypes mappings withNewPath of
          Right typed ->
            if newPath `elem` visitedDefinitions
            then return (trace ("Already visited " ++ show newPath) (withNewPath, []))
            else do (concrete, deps) <- concretizeXObj allowAmbiguity typeEnv globalEnv (newPath : visitedDefinitions) typed
                    (managed, memDeps) <- manageMemory typeEnv globalEnv concrete
                    return (managed, deps ++ memDeps)
          Left e -> Left e
      XObj (Lst (XObj (Deftemplate (TemplateCreator templateCreator)) _ _ : _)) _ _ ->
        let template = templateCreator typeEnv globalEnv
        in  Right (instantiateTemplate newPath concreteType template)
      XObj (Lst [XObj (External _) _ _, _]) _ _ ->
        if name == "NULL"
        then Right (definition, []) -- A hack to make all versions of NULL have the same name
        else let withNewPath = setPath definition newPath
                 withNewType = withNewPath { ty = Just concreteType }
             in  Right (withNewType, [])
      XObj (Lst [XObj (Instantiate template) _ _, _]) _ _ ->
        Right (instantiateTemplate newPath concreteType template)
      err ->
        Left $ CannotConcretize definition

-- | Find ALL functions with a certain name, matching a type signature.
allFunctionsWithNameAndSignature env functionName functionType =
  filter (predicate . ty . binderXObj . snd) (multiLookupALL functionName env)
  where
    predicate (Just t) = --trace ("areUnifiable? " ++ show functionType ++ " == " ++ show t ++ " " ++ show (areUnifiable functionType t)) $
                         areUnifiable functionType t

-- | Find all the dependencies of a polymorphic function with a name and a desired concrete type.
depsOfPolymorphicFunction :: TypeEnv -> Env -> [SymPath] -> String -> Ty -> [XObj]
depsOfPolymorphicFunction typeEnv env visitedDefinitions functionName functionType =
  case allFunctionsWithNameAndSignature env functionName functionType of
    [] ->
      (trace $ "[Warning] No '" ++ functionName ++ "' function found with type " ++ show functionType ++ ".")
      []
    -- TODO: this code was added to solve a bug (presumably) but it seems OK to comment it out?!
    -- [(_, (Binder xobj@(XObj (Lst (XObj (Instantiate template) _ _ : _)) _ _)))] ->
    --   []
    [(_, Binder _ single)] ->
      case concretizeDefinition False typeEnv env visitedDefinitions single functionType of
        Left err -> error (show err)
        Right (ok, deps) -> ok : deps
    _ ->
      (trace $ "Too many '" ++ functionName ++ "' functions found with type " ++ show functionType ++ ", can't figure out dependencies.")
      []

-- | Helper for finding the 'delete' function for a type.
depsForDeleteFunc :: TypeEnv -> Env -> Ty -> [XObj]
depsForDeleteFunc typeEnv env t =
  if isManaged typeEnv t
  then depsOfPolymorphicFunction typeEnv env [] "delete" (FuncTy [t] UnitTy)
  else []

-- | Helper for finding the 'copy' function for a type.
depsForCopyFunc :: TypeEnv -> Env -> Ty -> [XObj]
depsForCopyFunc typeEnv env t =
  if isManaged typeEnv t
  then depsOfPolymorphicFunction typeEnv env [] "copy" (FuncTy [RefTy t] t)
  else []

-- | Helper for finding the 'str' function for a type.
depsForPrnFunc :: TypeEnv -> Env -> Ty -> [XObj]
depsForPrnFunc typeEnv env t =
  if isManaged typeEnv t
  then depsOfPolymorphicFunction typeEnv env [] "prn" (FuncTy [RefTy t] StringTy)
  else depsOfPolymorphicFunction typeEnv env [] "prn" (FuncTy [t] StringTy)

-- | The type of a type's str function.
typesStrFunctionType :: TypeEnv -> Ty -> Ty
typesStrFunctionType typeEnv memberType =
  if isManaged typeEnv memberType
  then FuncTy [RefTy memberType] StringTy
  else FuncTy [memberType] StringTy

-- | The various results when trying to find a function using 'findFunctionForMember'.
data FunctionFinderResult = FunctionFound String
                          | FunctionNotFound String
                          | FunctionIgnored
                          deriving (Show)

getConcretizedPath :: XObj -> Ty -> SymPath
getConcretizedPath single functionType =
  let Just t' = ty single
      (SymPath pathStrings name) = getPath single
      suffix = polymorphicSuffix t' functionType
  in SymPath pathStrings (name ++ suffix)

-- | Used for finding functions like 'delete' or 'copy' for members of a Deftype (or Array).
findFunctionForMember :: TypeEnv -> Env -> String -> Ty -> (String, Ty) -> FunctionFinderResult
findFunctionForMember typeEnv env functionName functionType (memberName, memberType)
  | isManaged typeEnv memberType =
    case allFunctionsWithNameAndSignature env functionName functionType of
      [] -> FunctionNotFound ("Can't find any '" ++ functionName ++ "' function for member '" ++
                              memberName ++ "' of type " ++ show functionType)
      [(_, Binder _ single)] ->
        let concretizedPath = getConcretizedPath single functionType
        in  FunctionFound (pathToC concretizedPath)
      _ -> FunctionNotFound ("Can't find a single '" ++ functionName ++ "' function for member '" ++
                             memberName ++ "' of type " ++ show functionType)
  | otherwise = FunctionIgnored

-- | TODO: should this be the default and 'findFunctionForMember' be the specific one
findFunctionForMemberIncludePrimitives :: TypeEnv -> Env -> String -> Ty -> (String, Ty) -> FunctionFinderResult
findFunctionForMemberIncludePrimitives typeEnv env functionName functionType (memberName, memberType) =
  case allFunctionsWithNameAndSignature env functionName functionType of
    [] -> FunctionNotFound ("Can't find any '" ++ functionName ++ "' function for member '" ++
                            memberName ++ "' of type " ++ show functionType)
    [(_, Binder _ single)] ->
      let concretizedPath = getConcretizedPath single functionType
      in  FunctionFound (pathToC concretizedPath)
    _ -> FunctionNotFound ("Can't find a single '" ++ functionName ++ "' function for member '" ++
                           memberName ++ "' of type " ++ show functionType)



-- | Manage memory needs access to the concretizer
-- | (and the concretizer needs to manage memory)
-- | so they are put into the same module.

-- | Assign a set of Deleters to the 'infoDelete' field on Info.
setDeletersOnInfo :: Maybe Info -> Set.Set Deleter -> Maybe Info
setDeletersOnInfo i deleters = fmap (\i' -> i' { infoDelete = deleters }) i

-- | Helper function for setting the deleters for an XObj.
del :: XObj -> Set.Set Deleter -> XObj
del xobj deleters = xobj { info = setDeletersOnInfo (info xobj) deleters }

-- | To keep track of the deleters when recursively walking the form.
data MemState = MemState
                { memStateDeleters :: Set.Set Deleter
                , memStateDeps :: [XObj]
                } deriving Show

-- | Find out what deleters are needed and where in an XObj.
-- | Deleters will be added to the info field on XObj so that
-- | the code emitter can access them and insert calls to destructors.
manageMemory :: TypeEnv -> Env -> XObj -> Either TypeError (XObj, [XObj])
manageMemory typeEnv globalEnv root =
  let (finalObj, finalState) = runState (visit root) (MemState (Set.fromList []) [])
      deleteThese = memStateDeleters finalState
      deps = memStateDeps finalState
  in  -- (trace ("Delete these: " ++ joinWithComma (map show (Set.toList deleteThese)))) $
      case finalObj of
        Left err -> Left err
        Right ok -> let newInfo = fmap (\i -> i { infoDelete = deleteThese }) (info ok)
                    in  Right $ (ok { info = newInfo }, deps)

  where visit :: XObj -> State MemState (Either TypeError XObj)
        visit xobj =
          case obj xobj of
            Lst _ -> visitList xobj
            Arr _ -> visitArray xobj
            Str _ -> do manage xobj
                        return (Right xobj)
            _ -> return (Right xobj)

        visitArray :: XObj -> State MemState (Either TypeError XObj)
        visitArray xobj@(XObj (Arr arr) _ _) =
          do mapM_ visit arr
             results <- mapM unmanage arr
             case sequence results of
               Left e -> return (Left e)
               Right _ ->
                 do _ <- manage xobj -- TODO: result is discarded here, is that OK?
                    return (Right xobj)

        visitArray _ = error "Must visit array."

        visitList :: XObj -> State MemState (Either TypeError XObj)
        visitList xobj@(XObj (Lst lst) i t) =
          case lst of
            [defn@(XObj Defn _ _), nameSymbol@(XObj (Sym _ _) _ _), args@(XObj (Arr argList) _ _), body] ->
              let Just funcTy@(FuncTy _ defnReturnType) = t
              in case defnReturnType of
                   RefTy _ ->
                     return (Left (FunctionsCantReturnRefTy xobj funcTy))
                   _ ->
                     do mapM_ manage argList
                        visitedBody <- visit body
                        result <- unmanage body
                        return $
                          case result of
                            Left e -> Left e
                            Right _ ->
                              do okBody <- visitedBody
                                 return (XObj (Lst [defn, nameSymbol, args, okBody]) i t)

            [def@(XObj Def _ _), nameSymbol@(XObj (Sym _ _) _ _), expr] ->
              do visitedExpr <- visit expr
                 result <- unmanage expr
                 return $
                   case result of
                     Left e -> Left e
                     Right () ->
                       do okExpr <- visitedExpr
                          return (XObj (Lst [def, nameSymbol, okExpr]) i t)

            [letExpr@(XObj Let _ _), XObj (Arr bindings) bindi bindt, body] ->
              let Just letReturnType = t
              in case letReturnType of
                RefTy _ ->
                  return (Left (LetCantReturnRefTy xobj letReturnType))
                _ ->
                  do MemState preDeleters _ <- get
                     visitedBindings <- mapM visitLetBinding (pairwise bindings)
                     visitedBody <- visit body
                     result <- unmanage body
                     case result of
                       Left e -> return (Left e)
                       Right _ ->
                         do MemState postDeleters deps <- get
                            let diff = postDeleters Set.\\ preDeleters
                                newInfo = setDeletersOnInfo i diff
                                survivors = postDeleters Set.\\ diff -- Same as just pre deleters, right?!
                            put (MemState survivors deps)
                            --trace ("LET Pre: " ++ show preDeleters ++ "\nPost: " ++ show postDeleters ++ "\nDiff: " ++ show diff ++ "\nSurvivors: " ++ show survivors)
                            manage xobj
                            return $ do okBody <- visitedBody
                                        okBindings <- fmap (concatMap (\(n,x) -> [n, x])) (sequence visitedBindings)
                                        return (XObj (Lst [letExpr, XObj (Arr okBindings) bindi bindt, okBody]) newInfo t)

            -- Set!
            [setbangExpr@(XObj SetBang _ _), variable, value] ->
                 let varInfo = info variable
                     correctVariableAndMode =
                       case variable of
                         -- DISABLE FOR NOW: (XObj (Lst (XObj (Sym (SymPath _ "copy") _) _ _ : symObj@(XObj (Sym _ _) _ _) : _)) _ _) -> Right symObj
                         symObj@(XObj (Sym _ mode) _ _) -> Right (symObj, mode)
                         anythingElse -> Left (CannotSet anythingElse)
                 in
                 case correctVariableAndMode of
                   Left err ->
                     return (Left err)
                   Right (okCorrectVariable, okMode) ->
                     do MemState preDeleters _ <- get
                        ownsTheVarBefore <- case createDeleter okCorrectVariable of
                                              Nothing -> return (Right ())
                                              Just d -> if Set.member d preDeleters || okMode == LookupGlobal
                                                        then return (Right ())
                                                        else return (Left (UsingUnownedValue variable))

                        visitedValue <- visit value
                        unmanage value -- The assigned value can't be used anymore
                        MemState managed deps <- get
                        -- Delete the value previously stored in the variable, if it's still alive
                        let deleters = case createDeleter okCorrectVariable of
                                         Just d  -> Set.fromList [d]
                                         Nothing -> Set.empty
                            newVariable =
                              case okMode of
                                Symbol -> error "How to handle this?"
                                LookupLocal ->
                                  if Set.size (Set.intersection managed deleters) == 1 -- The variable is still alive
                                  then variable { info = setDeletersOnInfo varInfo deleters }
                                  else variable -- don't add the new info = no deleter
                                LookupGlobal ->
                                  variable { info = setDeletersOnInfo varInfo deleters }

                            traceDeps = trace ("SET!-deleters for " ++ pretty xobj ++ " at " ++ prettyInfoFromXObj xobj ++ ":\n" ++
                                               "unmanaged " ++ pretty value ++ "\n" ++
                                               "managed: " ++ show managed ++ "\n" ++
                                               "deleters: " ++ show deleters ++ "\n")

                        case okMode of
                          Symbol -> error "Should only be be a global/local lookup symbol."
                          LookupLocal -> manage okCorrectVariable
                          LookupGlobal -> return ()

                        return $ do okValue <- visitedValue
                                    okOwnsTheVarBefore <- ownsTheVarBefore -- Force Either to fail
                                    return (XObj (Lst [setbangExpr, newVariable, okValue]) i t)

            [addressExpr@(XObj Address _ _), value] ->
              do visitedValue <- visit value
                 return $ do okValue <- visitedValue
                             return (XObj (Lst [addressExpr, okValue]) i t)

            [theExpr@(XObj The _ _), typeXObj, value] ->
              do visitedValue <- visit value
                 result <- transferOwnership value xobj
                 return $ case result of
                            Left e -> Left e
                            Right _ -> do okValue <- visitedValue
                                          return (XObj (Lst [theExpr, typeXObj, okValue]) i t)

            [refExpr@(XObj Ref _ _), value] ->
              do visitedValue <- visit value
                 case visitedValue of
                   Left e -> return (Left e)
                   Right visitedValue ->
                     do checkResult <- refCheck visitedValue
                        case checkResult of
                          Left e -> return (Left e)
                          Right () -> return $ Right (XObj (Lst [refExpr, visitedValue]) i t)

            doExpr@(XObj Do _ _) : expressions ->
              do visitedExpressions <- mapM visit expressions
                 result <- transferOwnership (last expressions) xobj
                 return $ case result of
                            Left e -> Left e
                            Right _ -> do okExpressions <- sequence visitedExpressions
                                          return (XObj (Lst (doExpr : okExpressions)) i t)

            [whileExpr@(XObj While _ _), expr, body] ->
              do MemState preDeleters _ <- get
                 visitedExpr <- visit expr
                 MemState afterExprDeleters _ <- get
                 visitedBody <- visit body
                 manage body
                 MemState postDeleters deps <- get
                 -- Visit an extra time to simulate repeated use
                 visitedExpr2 <- visit expr
                 visitedBody2 <- visit body
                 let diff = postDeleters \\ preDeleters
                 put (MemState (postDeleters \\ diff) deps) -- Same as just pre deleters, right?!
                 return $ do okExpr <- visitedExpr
                             okBody <- visitedBody
                             okExpr2 <- visitedExpr2 -- This evaluates the second visit so that it actually produces the error
                             okBody2 <- visitedBody2 -- And this one too. Laziness FTW.
                             let newInfo = setDeletersOnInfo i diff
                                 -- Also need to set deleters ON the expression (for first run through the loop)
                                 XObj objExpr objInfo objTy = okExpr
                                 newExprInfo = setDeletersOnInfo objInfo (afterExprDeleters \\ preDeleters)
                                 newExpr = XObj objExpr newExprInfo objTy
                             return (XObj (Lst [whileExpr, newExpr, okBody]) newInfo t)

            [ifExpr@(XObj If _ _), expr, ifTrue, ifFalse] ->
              do visitedExpr <- visit expr
                 MemState preDeleters deps <- get

                 let (visitedTrue,  stillAliveTrue)  = runState (do { v <- visit ifTrue;
                                                                      result <- transferOwnership ifTrue xobj;
                                                                      return $ case result of
                                                                                 Left e -> error (show e) -- Left e
                                                                                 Right () -> v
                                                                    })
                                                       (MemState preDeleters deps)

                     (visitedFalse, stillAliveFalse) = runState (do { v <- visit ifFalse;
                                                                      result <- transferOwnership ifFalse xobj;
                                                                      return $ case result of
                                                                                 Left e -> error (show e) -- Left e
                                                                                 Right () -> v
                                                                    })
                                                       (MemState preDeleters deps)

                 let -- TODO! Handle deps from stillAliveTrue/stillAliveFalse
                     deletedInTrue  = preDeleters \\ (memStateDeleters stillAliveTrue)
                     deletedInFalse = preDeleters \\ (memStateDeleters stillAliveFalse)
                     deletedInBoth  = Set.intersection deletedInTrue deletedInFalse
                     createdInTrue  = (memStateDeleters stillAliveTrue)  \\ preDeleters
                     createdInFalse = (memStateDeleters stillAliveFalse) \\ preDeleters
                     selfDeleter = case createDeleter xobj of
                                     Just ok -> Set.fromList [ok]
                                     Nothing -> Set.empty
                     createdAndDeletedInTrue  = createdInTrue  \\ selfDeleter
                     createdAndDeletedInFalse = createdInFalse \\ selfDeleter
                     delsTrue  = Set.union (deletedInFalse \\ deletedInBoth) createdAndDeletedInTrue
                     delsFalse = Set.union (deletedInTrue  \\ deletedInBoth) createdAndDeletedInFalse
                     stillAliveAfter = preDeleters \\ (Set.union deletedInTrue deletedInFalse)

                     traceDeps = trace ("IF-deleters for " ++ pretty xobj ++ " at " ++ prettyInfoFromXObj xobj ++ " " ++ identifierStr xobj ++ ":\n" ++
                                        "preDeleters: " ++ show (preDeleters) ++ "\n" ++
                                        "stillAliveTrue: " ++ show (memStateDeleters stillAliveTrue) ++ "\n" ++
                                        "stillAliveFalse: " ++ show (memStateDeleters stillAliveFalse) ++ "\n" ++
                                        "createdInTrue: " ++ show (createdInTrue) ++ "\n" ++
                                        "createdInFalse: " ++ show (createdInFalse) ++ "\n" ++
                                        "createdAndDeletedInTrue: " ++ show (createdAndDeletedInTrue) ++ "\n" ++
                                        "createdAndDeletedInFalse: " ++ show (createdAndDeletedInFalse) ++ "\n" ++
                                        "deletedInTrue: " ++ show (deletedInTrue) ++ "\n" ++
                                        "deletedInFalse: " ++ show (deletedInFalse) ++ "\n" ++
                                        "deletedInBoth: " ++ show (deletedInBoth) ++ "\n" ++
                                        "delsTrue: " ++ show (delsTrue) ++ "\n" ++
                                        "delsFalse: " ++ show (delsFalse) ++ "\n" ++
                                        "stillAlive: " ++ show (stillAliveAfter) ++ "\n"
                                       )

                 put (MemState stillAliveAfter deps)
                 manage xobj

                 return $ do okExpr  <- visitedExpr
                             okTrue  <- visitedTrue
                             okFalse <- visitedFalse
                             return (XObj (Lst [ifExpr, okExpr, del okTrue delsTrue, del okFalse delsFalse]) i t)
            f : args ->
              do visitedF <- visit f
                 visitedArgs <- sequence <$> mapM visitArg args
                 manage xobj
                 return $ do okF <- visitedF
                             okArgs <- visitedArgs
                             Right (XObj (Lst (okF : okArgs)) i t)

            [] -> return (Right xobj)
        visitList _ = error "Must visit list."

        visitLetBinding :: (XObj, XObj) -> State MemState (Either TypeError (XObj, XObj))
        visitLetBinding (name, expr) =
          do visitedExpr <- visit expr
             result <- transferOwnership expr name
             return $ case result of
                        Left e -> Left e
                        Right _ -> do okExpr <- visitedExpr
                                      return (name, okExpr)

        visitArg :: XObj -> State MemState (Either TypeError XObj)
        visitArg xobj@(XObj _ _ (Just t)) =
          if isManaged typeEnv t
          then do visitedXObj <- visit xobj
                  result <- unmanage xobj
                  case result of
                    Left e  -> return (Left e)
                    Right _ -> return visitedXObj
          else visit xobj
        visitArg xobj@XObj{} =
          visit xobj

        createDeleter :: XObj -> Maybe Deleter
        createDeleter xobj =
          case ty xobj of
            Just t -> let var = varOfXObj xobj
                      in  if isManaged typeEnv t && not (isExternalType typeEnv t)
                          then case nameOfPolymorphicFunction typeEnv globalEnv (FuncTy [t] UnitTy) "delete" of
                                 Just pathOfDeleteFunc -> Just (ProperDeleter pathOfDeleteFunc var)
                                 Nothing -> --trace ("Found no delete function for " ++ var ++ " : " ++ (showMaybeTy (ty xobj)))
                                            Just (FakeDeleter var)
                          else Nothing
            Nothing -> error ("No type, can't manage " ++ show xobj)

        manage :: XObj -> State MemState ()
        manage xobj =
          case createDeleter xobj of
            Just deleter -> do MemState deleters deps <- get
                               let newDeleters = Set.insert deleter deleters
                                   Just t = ty xobj
                                   newDeps = deps ++ depsForDeleteFunc typeEnv globalEnv t
                               put (MemState newDeleters newDeps)
            Nothing -> return ()

        deletersMatchingXObj :: XObj -> Set.Set Deleter -> [Deleter]
        deletersMatchingXObj xobj deleters =
          let var = varOfXObj xobj
          in  Set.toList $ Set.filter (\d -> case d of
                                               ProperDeleter { deleterVariable = dv } -> dv == var
                                               FakeDeleter   { deleterVariable = dv } -> dv == var)
                                      deleters

        unmanage :: XObj -> State MemState (Either TypeError ())
        unmanage xobj =
          let Just t = ty xobj
              Just i = info xobj
          in if isManaged typeEnv t && not (isExternalType typeEnv t)
             then do MemState deleters deps <- get
                     case deletersMatchingXObj xobj deleters of
                       [] -> return (Left (UsingUnownedValue xobj))
                       [one] -> let newDeleters = Set.delete one deleters
                                in  do put (MemState newDeleters deps)
                                       return (Right ())
                       _ -> error "Too many variables with the same name in set."
             else return (Right ())

        -- | Check that the value being referenced hasn't already been given away
        refCheck :: XObj -> State MemState (Either TypeError ())
        refCheck xobj =
          let Just i = info xobj
              Just t = ty xobj
              isGlobalVariable = case xobj of
                                   XObj (Sym _ LookupGlobal) _ _ -> True
                                   _ -> False
          in if not isGlobalVariable && isManaged typeEnv t && not (isExternalType typeEnv t)
             then do MemState deleters deps <- get
                     case deletersMatchingXObj xobj deleters of
                       [] ->  return (Left (GettingReferenceToUnownedValue xobj))
                       [_] -> return (return ())
                       _ -> error "Too many variables with the same name in set."
             else return (return ())

        transferOwnership :: XObj -> XObj -> State MemState (Either TypeError ())
        transferOwnership from to =
          do result <- unmanage from
             case result of
               Left e -> return (Left e)
               Right _ -> do manage to --(trace ("Transfered from " ++ getName from ++ " '" ++ varOfXObj from ++ "' to " ++ getName to ++ " '" ++ varOfXObj to ++ "'") to)
                             return (Right ())

        varOfXObj :: XObj -> String
        varOfXObj xobj =
          case xobj of
            XObj (Sym (SymPath [] name) _) _ _ -> name
            _ -> let Just i = info xobj
                 in  freshVar i

suffixTyVars :: String -> Ty -> Ty
suffixTyVars suffix t =
  case t of
    (VarTy key) -> (VarTy (key ++ suffix))
    (FuncTy argTys retTy) -> FuncTy (map (suffixTyVars suffix) argTys) (suffixTyVars suffix retTy)
    (StructTy name tyArgs) -> StructTy name (fmap (suffixTyVars suffix) tyArgs)
    (PointerTy x) -> PointerTy (suffixTyVars suffix x)
    (RefTy x) -> RefTy (suffixTyVars suffix x)
    _ -> t
