module Infer(
InferredStatement,
InferredExpr,
inferStatement,
inferType,
emptyScope
) where

import Types
--import Pretty

-- TODO:
--
-- * generalize funcs/variables (without allowing incompatible assignments!)
-- 
-- * change pretty printer to annotate original source instead of printing AST from scratch
-- 
-- * infer record types by their usage in a function
-- 
-- * support 'this' by assuming equivalences:
--   - f(..) == f.bind(window, ..)
--   - o.f(..) == f.bind(o, ..)
--
-- * support new (e.g. add body Constructor ... that's like a func
-- 
-- * check zips for missing errors (zip of lists of different sizes)
--
-- * don't allow assigning to function args? (lint issue only)

--import Control.Error
import Data.Functor((<$>))
import Data.Functor.Identity(Identity(..))
import Data.Maybe(fromJust) --, fromMaybe)
import Control.Monad.State(State, runState, get, put)
import Control.Monad.Trans(lift)
import Control.Monad.Trans.Either(EitherT(..), left)
import Data.Traversable(Traversable(..), forM, mapM)
import Data.Foldable(toList)
import qualified Data.Map.Lazy as Map
import Prelude hiding (foldr, mapM, sequence)

type InferredStatement = Statement InferredExpr
type InferredExpr = Expr JSType
type Inference a = EitherT TypeError (State Scope) a

-- getVarType = bad name, because it isn't = lookup name . getVars
getVarType :: VarScope -> String -> Maybe JSType
getVarType Global _ = Nothing
getVarType scope name = case lookup name (vars scope) of
                       Nothing -> getVarType (parent scope) name
                       Just t -> Just t

intrVars :: Traversable t => t String -> State Scope (VarScope, t JSType)
intrVars names = do
  scope <- get
  let varScope' = varScope scope
  vs <- forM names $ \name -> do
          varType' <-  allocTVar
          return (name, varType')

  return (VarScope { parent = varScope', vars = toList vs }, fmap snd vs)

updateVarScope :: VarScope -> State Scope [JSType]
updateVarScope v = do
  scope <- get
  put $ scope { varScope = v }
  return . map snd $ vars v

allocTVar :: State Scope JSType
allocTVar = do
  scope <- get
  let typeScope' = typeScope scope
      updatedScope = typeScope' { maxNum = allocedNum }
      allocedNum = maxNum typeScope' + 1
  put $ scope { typeScope = updatedScope }
  return $ JSTVar allocedNum

emptyTypeScope :: TypeScope
emptyTypeScope = TypeScope { tVars = Map.empty, maxNum = 0, tEnv = Map.empty }

emptyScope :: Scope
emptyScope = Scope { typeScope = emptyTypeScope, funcScope = Nothing, varScope = Global }

 

getFuncScope :: Scope -> Either TypeError FuncScope
getFuncScope = maybe (Left $ TypeError "Not in a function scope") Right . funcScope

getFuncReturnType :: Inference JSType
getFuncReturnType = do
  funcScope' <- EitherT $ getFuncScope <$> get
  return $ returnType funcScope'

setFuncReturnType :: JSType -> Inference ()
setFuncReturnType retType = do
  scope <- get
  funcScope' <- EitherT . return $ getFuncScope scope
  put $ scope { funcScope = Just $ funcScope' { returnType = retType } }

coerceTypes :: JSType -> JSType -> Inference JSType
coerceTypes t u = do
  scope <- get
  let typeScope' = typeScope scope
  let tsubst = tVars typeScope'
  tsubst' <- EitherT . return $ unify tsubst (toType t) (toType u)
  put scope { typeScope = typeScope' { tVars = tsubst' } }
  return . fromType $ substituteType tsubst' (toType t)

resolveType :: TypeScope -> JSType -> JSType
resolveType ts t = fromType . subst' $ toType t
  where tsubst = tVars ts
        subst' t' = case substituteType tsubst t' of
                      t''@(TVar _) -> if t' == t'' then t'
                                      else subst' t''
                      TCons consName ts' -> 
                          let substTS = map subst' ts' in
                          TCons consName substTS



inferStatement ::  Statement (Expr a) -> Inference InferredStatement
inferStatement st =
  case st of
    Empty -> return Empty
    Expression expr -> inferExprStatement expr
    Block xs -> inferBlockStatement xs
    IfThenElse expr stThen stElse -> inferIfThenElse  expr stThen stElse 
    Return Nothing -> inferReturnNothing
    Return (Just expr) -> inferReturnExpr expr
    While expr stWhile -> inferWhile expr stWhile
    VarDecl name -> lift $ inferVarDecl name

inferVarDecl :: String -> State Scope InferredStatement
inferVarDecl name =         
    do (updatedVarScope, _) <- intrVars [name]
       _ <- updateVarScope updatedVarScope
       return $ VarDecl name

inferWhile :: Expr a -> Statement (Expr a) -> Inference InferredStatement
inferWhile expr stWhile =
    do inferredExpr <- inferType expr
       inferredStWhile <- inferStatement stWhile
       let newSt = While inferredExpr inferredStWhile
       _ <- coerceTypes (exprData inferredExpr) JSBoolean
       return newSt

inferReturnExpr :: Expr a -> Inference InferredStatement
inferReturnExpr expr =
    do inferredExpr <- inferReturnType expr
       return . Return $ Just inferredExpr

inferReturnNothing :: Inference InferredStatement
inferReturnNothing = 
    do returnT <- getFuncReturnType
       t <- coerceTypes returnT JSUndefined
       setFuncReturnType t
       return $ Return Nothing

inferIfThenElse :: Expr a -> Statement (Expr a) -> Statement (Expr a) -> Inference InferredStatement
inferIfThenElse expr stThen stElse = 
    do inferredExpr <- inferType expr
       stThen' <- inferStatement stThen
       stElse' <- inferStatement stElse
       let newSt = IfThenElse inferredExpr stThen' stElse'
       _ <- coerceTypes (exprData inferredExpr) JSBoolean
       return newSt

inferExprStatement :: Expr a -> Inference InferredStatement
inferExprStatement expr = 
    do inferredExpr <- inferType expr
       return $ Expression inferredExpr 

inferBlockStatement :: [Statement (Expr a)] -> Inference InferredStatement
inferBlockStatement xs =
    do results <- mapM inferStatement xs
       return $ Block results

inferType :: Expr a -> Inference InferredExpr
inferType e = do
  inferredExpr <- inferType' e
  scope <- lift get
  return $ fmap (resolveType $ typeScope scope) inferredExpr
  --resolve inferredExpr

inferType' ::   Expr a -> Inference InferredExpr
inferType' (Expr body _) =
  case body of
    LitArray exprs -> inferArrayType exprs
    LitBoolean x -> simpleType JSBoolean $ LitBoolean x
    LitFunc name argNames exprs -> inferFuncType name argNames exprs
    LitNumber x -> simpleType JSNumber $ LitNumber x
    LitObject props -> inferObjectType props
    LitRegex x -> simpleType JSRegex $ LitRegex x
    LitString x -> simpleType JSString $ LitString x
    Var name -> inferVarType name
    Call callee args -> inferCallType callee args
    Assign dest src -> inferAssignType dest src
    Property expr name -> inferPropertyType expr name
    Index arrExpr indexExpr -> inferIndexType arrExpr indexExpr
  where simpleType t body' = return $ Expr body' t

        
inferIndexType :: Expr a -> Expr a  -> Inference InferredExpr
inferIndexType arrExpr indexExpr = do
  inferredArrExpr <- inferType arrExpr
  inferredIndexExpr <- inferType indexExpr
  let newBody = Index inferredArrExpr inferredIndexExpr
      Expr _ (JSArray elemType) = inferredArrExpr
  return $ Expr newBody elemType

inferAssignType :: Expr a -> Expr a -> Inference InferredExpr
inferAssignType dest src = do
  inferredDest <- inferType dest
  inferredSrc <- inferType src
  let newBody = Assign inferredDest inferredSrc
  let destType = exprData inferredDest
      srcType = exprData inferredSrc
      infer' = do
        varType <- coerceTypes destType srcType
        return $ Expr newBody varType
  case exprBody inferredDest of
    Var _ -> infer'
    Property _ _ -> infer' -- TODO update object type?
    _ -> left $ TypeError "Left-hand side of assignment is not an lvalue"

inferPropertyType :: Expr a -> String -> Inference InferredExpr
inferPropertyType objExpr propName =
    do inferredObjExpr <- inferType objExpr
       let newBody = Property inferredObjExpr propName
           objType = getObjPropertyType (exprData inferredObjExpr) propName 
       case objType of
         Nothing -> left $ TypeError ("object type has no property named '" ++ propName ++ "'")
         Just propType' -> return $ Expr newBody propType'

inferCallType :: Expr a -> [Expr a] -> Inference InferredExpr
inferCallType callee args = do
  inferredCallee <- inferType callee
  inferredArgs <- mapM inferType args
  callResultType <- lift allocTVar
  let newBody = Call inferredCallee inferredArgs
  let argTypes = map exprData inferredArgs
  JSFunc _ returnType' <- coerceTypes (exprData inferredCallee) (JSFunc argTypes callResultType)
  return $ Expr newBody returnType'
  
inferVarType :: String -> Inference InferredExpr
inferVarType name = do
  scope <- get
  let varType = getVarType (varScope scope) name
  case varType of 
    Nothing -> left . TypeError $ "undeclared variable: " ++ name
    Just varType' -> return $ Expr (Var name) varType'

inferArrayType :: [Expr a] -> Inference InferredExpr
inferArrayType exprs = 
    do inferredExprs <- forM exprs inferType
       let newBody = LitArray inferredExprs
       case inferredExprs of
         [] -> do elemType <- lift allocTVar
                  return $ Expr newBody (JSArray elemType)
         (x:xs) -> do
           let headElemType = exprData x
           _ <- forM (map exprData xs) (coerceTypes headElemType)
           return $ Expr newBody (JSArray headElemType)

inferFuncType :: Maybe String -> [String] -> [Statement (Expr a)] -> Inference InferredExpr
inferFuncType name argNames exprs =
    do returnType' <- lift allocTVar
       -- if the function has a name, introduce it as a variable to the var context before the argument names
       funcType <- 
           case name of
             Just x -> 
                 do (varScope', Identity varType) <- lift . intrVars $ Identity x
                    _ <- lift $ updateVarScope varScope'
                    return varType
             Nothing -> lift allocTVar
       -- allocate variables for the arguments
       (argScope, argTypes) <- lift $ intrVars argNames
       let funcScope' = FuncScope { returnType = returnType' }
       scope <- get
       -- infer the statements that make up this function
       let (inferredStatments, Scope typeScope'' _ updatedFuncScope) = 
                 flip runState scope { funcScope = Just funcScope', varScope = argScope } 
                          . runEitherT
                          $ forM exprs inferStatement
       -- update scope with type/unification changes from the statements' processing
       put $ scope { typeScope = typeScope'' }
       inferredStatments' <- EitherT . return $ inferredStatments
       let newBody = LitFunc name argNames inferredStatments'
       let inferredReturnType = returnType $ fromJust updatedFuncScope -- not supposed to be Nothing...
       unifiedReturnType <- coerceTypes returnType' inferredReturnType
       unifiedFuncType <- coerceTypes funcType . JSFunc argTypes $ unifiedReturnType
       return $ Expr newBody unifiedFuncType 

inferReturnType ::  Expr a -> Inference InferredExpr
inferReturnType expr =
    do e'@(Expr _ retType) <- inferType expr
       curReturnType <- getFuncReturnType
       _ <- coerceTypes retType curReturnType
       return e'
 
inferObjectType :: [(String, Expr a)] -> Inference InferredExpr
inferObjectType props =
    do let propNames = map fst props
       let propExprs = map snd props
       inferredProps <- mapM inferType propExprs
       let newBody = LitObject $ zip propNames inferredProps
       return . Expr newBody $ JSObject (zip propNames (map exprData inferredProps))

