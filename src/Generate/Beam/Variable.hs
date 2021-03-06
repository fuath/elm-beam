{-# LANGUAGE OverloadedStrings #-}
module Generate.Beam.Variable
  ( Def(..)
  , declare, define, defineLocal
  , standalone, explicitCall, genericCall
  , Context, initial, notTail
  ) where

import Data.Monoid ((<>))
import qualified Codec.Beam as Beam
import qualified Codec.Beam.Instructions as I
import qualified Data.Text as Text

import Reporting.Bag (Bag)
import qualified AST.Expression.Optimized as Opt
import qualified AST.Helpers as Help
import qualified AST.Module.Name as ModuleName
import qualified AST.Variable as Var
import qualified Elm.Package as Package
import qualified Generate.Beam.Environment as Env
import qualified Reporting.Bag as Bag


-- CREATE


declare :: ModuleName.Canonical -> Opt.Def -> Env.Gen ()
declare moduleName def =
  case def of
    Opt.Def _ name (Opt.Function args _) ->
      registerRequiredLabels moduleName name (length args)

    Opt.Def _ name _ ->
      registerRequiredLabels moduleName name 0

    Opt.TailDef _ name args _ ->
      registerRequiredLabels moduleName name (length args)


registerRequiredLabels :: ModuleName.Canonical -> String -> Int -> Env.Gen ()
registerRequiredLabels moduleName name arity =
  if alwaysExplicit name arity then
    Env.registerTopLevel moduleName name arity
  else
    Env.freshLabel >> Env.registerTopLevel moduleName name arity


data Def = Def
  { _def_args :: [ String ]
  , _def_body :: Opt.Expr
  , _def_ops :: Bag Beam.Op
  }


define :: ModuleName.Canonical -> Opt.Def -> Env.Gen Def
define moduleName def =
  case def of
    Opt.Def _ name (Opt.Function args expr) ->
      Def args expr <$> topLevelOps moduleName name

    Opt.Def _ name expr ->
      Def [] expr <$> topLevelOps moduleName name

    Opt.TailDef _ name args expr ->
      Def args expr <$> topLevelOps moduleName name


defineLocal :: Opt.Def -> Env.Gen ( Beam.Y, Opt.Expr )
defineLocal def =
  case def of
    Opt.Def _ name expr ->
      (,) <$> Env.registerLocal name <*> return expr

    Opt.TailDef _ _ _ _ ->
      error "TODO: tail-recursive let"


topLevelOps :: ModuleName.Canonical -> String -> Env.Gen (Bag Beam.Op)
topLevelOps moduleName name =
  do  Env.resetStackAllocation
      pre <- Env.freshLabel
      ( post, arity ) <- Env.getTopLevel moduleName name
      prefix <-
        if alwaysExplicit name arity then
          return Bag.empty
        else
          curriedOps function (Ctx post arity) (Ctx (curriedOffset post) 1)
      return $ Bag.append prefix $ Bag.fromList
        [ I.label pre
        , I.func_info function arity
        , I.label post
        ]
  where
    function = namespace moduleName name


alwaysExplicit :: String -> Int -> Bool
alwaysExplicit name arity =
  Help.isOp name || arity <= 1


namespace :: ModuleName.Canonical -> String -> Text.Text
namespace (ModuleName.Canonical package name) var =
  Text.pack $ Package.toString package
    ++ "/" ++ ModuleName.toString name
    ++ "#" ++ var


curriedOffset :: Beam.Label -> Beam.Label
curriedOffset (Beam.Label i) =
  Beam.Label (i - 1)



-- TAIL CALL

newtype Context = Context { _isTailCall :: Bool }

initial :: Context
initial = Context True

notTail :: Context
notTail = Context False



-- SETUP CURRYING


data Ctx = Ctx
  { _ctx_label :: Beam.Label
  , _ctx_arity :: Int
  }


curriedOps :: Text.Text -> Ctx -> Ctx -> Env.Gen (Bag Beam.Op)
curriedOps name original current =
  if _ctx_arity original == _ctx_arity current then
    do  pre <- Env.freshLabel
        return $ concatBags id
          [ Bag.fromList
              [ I.label pre
              , I.func_info (lambdaName current name) (_ctx_arity original)
              , I.label (_ctx_label current)
              ]
          , reverseXs original
          , Bag.fromList
              [ I.call_only (_ctx_arity original) (_ctx_label original)
              , I.return'
              ]
          ]
  else
    do  pre <- Env.freshLabel
        next <- Ctx <$> Env.freshLabel <*> return (_ctx_arity current + 1)
        Bag.append
          (Bag.fromList
            [ I.label pre
            , I.func_info (lambdaName current name) (_ctx_arity current)
            , I.label (_ctx_label current)
            , I.make_fun2 (Beam.Lambda
                { Beam._lambda_name = lambdaName next name
                , Beam._lambda_arity = 1
                , Beam._lambda_label = _ctx_label next
                , Beam._lambda_free = _ctx_arity current
                })
            , I.return'
            ])
          <$> curriedOps name original next


reverseXs :: Ctx -> Bag Beam.Op
reverseXs (Ctx _ arity) =
  reverseXsHelp (Beam.X arity) 0 (arity - 1)


reverseXsHelp :: Beam.X -> Int -> Int -> Bag Beam.Op
reverseXsHelp tmp start end =
  if end - start <= 0 then
    Bag.empty
  else
    Bag.append
      (Bag.fromList
        [ I.move (Beam.X end) tmp
        , I.move (Beam.X start) (Beam.X end)
        , I.move tmp (Beam.X start)
        ])
      (reverseXsHelp tmp (start + 1) (end - 1))


lambdaName :: Ctx -> Text.Text -> Text.Text
lambdaName (Ctx _ arity) baseName =
  Text.replicate arity "_" <> baseName



-- USE


standalone :: Context -> Var.Canonical -> Env.Gen Env.Value
standalone context (Var.Canonical home name) =
  case home of
    Var.BuiltIn             -> error "TODO"
    Var.Module moduleName   -> referToTopLevel context moduleName name
    Var.TopLevel moduleName -> referToTopLevel context moduleName name
    Var.Local               -> referToLocal name


explicitCall :: Context -> Var.Canonical -> [ Env.Value ] -> Env.Gen Env.Value
explicitCall context (Var.Canonical home name) args =
  case home of
    Var.BuiltIn             -> error "TODO"
    Var.Module moduleName   -> tryExactCall context moduleName name args
    Var.TopLevel moduleName -> tryExactCall context moduleName name args
    Var.Local               -> referToLocal name


tryExactCall :: Context -> ModuleName.Canonical -> String -> [ Env.Value ] -> Env.Gen Env.Value
tryExactCall context moduleName name args =
  do  ( label, arity ) <- Env.getTopLevel moduleName name
      if arity == length args
        then call Bag.empty $ qualified context label args
        else flip (genericCall context) args =<< referToTopLevel notTail moduleName name


genericCall :: Context -> Env.Value -> [ Env.Value ] -> Env.Gen Env.Value
genericCall context (Env.Value ops result) args =
  call ops $ curried result args


call :: Bag Beam.Op -> Bag Beam.Op -> Env.Gen Env.Value
call functionOps callOps =
  do  dest <- Env.freshStackAllocation
      let ops = concatBags id
            [ functionOps
            , callOps
            , Bag.singleton (I.move Env.returnRegister dest)
            ]
      return $ Env.Value ops (Beam.toSource dest)


referToTopLevel :: Context -> ModuleName.Canonical -> String -> Env.Gen Env.Value
referToTopLevel context moduleName name =
  do  ( label@(Beam.Label i), arity ) <- Env.getTopLevel moduleName name
      dest <- Env.freshStackAllocation
      return $ Env.Value
        (Bag.fromList
          [ referByArity context moduleName name label arity
          , I.move Env.returnRegister dest
          ])
        (Beam.toSource dest)


referByArity :: Context -> ModuleName.Canonical -> String -> Beam.Label -> Int -> Beam.Op
referByArity context moduleName name label arity =
  case arity of
    0 ->
      -- TODO: if tail context, use `call_last`
      I.call 0 label

    1 ->
      I.make_fun2 $ Beam.Lambda
        { Beam._lambda_name = "_REF@" <> namespace moduleName name
        , Beam._lambda_arity = 1
        , Beam._lambda_label = label
        , Beam._lambda_free = 0
        }

    _ ->
      I.make_fun2 $ Beam.Lambda
        { Beam._lambda_name = "__REF@" <> namespace moduleName name
        , Beam._lambda_arity = 1
        , Beam._lambda_label = curriedOffset label
        , Beam._lambda_free = 0
        }


referToLocal :: String -> Env.Gen Env.Value
referToLocal name =
  Env.Value Bag.empty . Beam.toSource <$> Env.getLocal name



-- DIFFERENT WAYS TO CALL A FUNCTION


qualified :: Context -> Beam.Label -> [ Env.Value ] -> Bag Beam.Op
qualified context label argValues =
  concatBags id
    [ concatBags Env.ops argValues
    , Bag.fromList (zipWith moveArg argValues [0..])
    -- TODO: if tail context, use `call_last`
    , Bag.singleton (I.call (length argValues) label)
    ]


moveArg :: Env.Value -> Int -> Beam.Op
moveArg value i =
  I.move (Env.result value) (Beam.X i)


curried :: Beam.Source -> [ Env.Value ] -> Bag Beam.Op
curried fun argValues =
  Bag.append (concatBags Env.ops argValues) (curriedHelp fun argValues)


curriedHelp :: Beam.IsSource s => s -> [ Env.Value ] -> Bag Beam.Op
curriedHelp fun argValues =
  case argValues of
    [] ->
      Bag.empty

    Env.Value _ arg : rest ->
      Bag.append
        (Bag.fromList
          [ I.move fun (Beam.X 1)
          , I.move arg (Beam.X 0)
          , I.call_fun 1
          ])
        (curriedHelp Env.returnRegister rest)


concatBags :: (a -> Bag b) -> [ a ] -> Bag b
concatBags _ []     = Bag.empty
concatBags f (a:as) = Bag.append (f a) (concatBags f as)
