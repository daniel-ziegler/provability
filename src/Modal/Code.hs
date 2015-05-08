{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Modal.Code where
import Control.Applicative
import Control.Arrow (second)
import Control.Monad (void)
import Control.Monad.Except
import Control.Monad.State
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.List as List
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Modal.Formulas (ModalFormula, (%^), (%|))
import qualified Modal.Formulas as L
import Modal.Programming hiding (modalProgram)
import Modal.GameTools (ModalProgram)
import Modal.Display
import Modal.Parser
import Modal.Utilities
import Text.Parsec hiding ((<|>), optional, many, State)
import Text.Parsec.Expr
import Text.Parsec.Text (Parser)
import Text.Printf (printf)

-- GOAL:
--
-- def UDT(U):
--   let $level = 0
--   for $o in theirActions
--     for $a in myActions
--        if □⌜UDT(U)=$a → U(UDT)=$o⌝
--          return $a
--        let $level = $level + 1

-------------------------------------------------------------------------------

data Void
instance Eq Void
instance Ord Void
instance Read Void
instance Show Void
instance Parsable Void where parser = fail "Cannot instantiate the Void."

-------------------------------------------------------------------------------

type Program a o = ModalProgram (ModalVar a o) a

data Agent a o = Agent { agentName :: Name, sourceCode :: Code a o } deriving Eq
instance (Enum a, Show a, Enum o, Show o) => Blockable (Agent a o) where
  blockLines (Agent n c) =
    (0, T.pack $ printf "def %s" (T.unpack n)) : increaseIndent (blockLines c)
instance (Enum a, Show a, Enum o, Show o) => Show (Agent a o) where
  show = T.unpack . renderBlock
instance (Ord a, Enum a, Parsable a, Ord o, Enum o, Parsable o) => Parsable (Agent a o) where
  parser = Agent <$> (keyword "def" *> name) <*> parser

compile :: (Eq a, Enum a, Enum o) => Agent a o -> Either ContextError (Name, Program a o)
compile (Agent n c) = second (L.simplify .) . (n,) <$> codeToFormula c

forceCompile :: (Eq a, Enum a, Enum o) => Agent a o -> (Name, Program a o)
forceCompile agent = let Right result = compile agent in result

-------------------------------------------------------------------------------

data Context a o = C { avars :: Map Name a, ovars :: Map Name o, nvars :: Map Name Int }
  deriving (Eq, Show)

data ContextError
  = UnknownAVar Name
  | UnknownOVar Name
  | UnknownNVar Name
  deriving (Eq, Ord, Show)

type Contextual a o m = (
  Applicative m,
  MonadState (Context a o) m,
  MonadError ContextError m)

type Evalable a o m = (
  Eq a, Enum a, Enum o,
  Applicative m,
  MonadState (Context a o) m,
  MonadError ContextError m)

emptyContext :: Context a o
emptyContext = C Map.empty Map.empty Map.empty

withA :: Name -> a -> Context a o -> Context a o
withA n a c = c{avars=Map.insert n a $ avars c}

withO :: Name -> o -> Context a o -> Context a o
withO n o c = c{ovars=Map.insert n o $ ovars c}

withN :: Name -> Int -> Context a o -> Context a o
withN n i c = c{nvars=Map.insert n i $ nvars c}

getA :: Contextual a o m => V a -> m a
getA (Vn n) = maybe (throwError $ UnknownAVar n) return . Map.lookup n . avars =<< get
getA (Vv a) = return a

getO :: Contextual a o m => V o -> m o
getO (Vn n) = maybe (throwError $ UnknownOVar n) return . Map.lookup n . ovars =<< get
getO (Vv o) = return o

getN :: Contextual a o m => V Int -> m Int
getN (Vn n) = maybe (throwError $ UnknownNVar n) return . Map.lookup n . nvars =<< get
getN (Vv i) = return i

-------------------------------------------------------------------------------

data ModalVar a o = MeVsThemIs a | ThemVsMeIs o | ThemVsOtherIs Name o deriving (Eq, Ord)
instance (Show a, Show o) => Show (ModalVar a o) where
  show (MeVsThemIs a) = "Me(Them)=" ++ show a
  show (ThemVsMeIs o) = "Them(Me)=" ++ show o
  show (ThemVsOtherIs n o) = "Them(" ++ T.unpack n ++ ")=" ++ show o

evalVar :: Contextual a o m =>
  ModalVar (Relation a) (Relation o) -> m (ModalFormula (ModalVar a o))
evalVar (MeVsThemIs rel) = evalRelation getA MeVsThemIs rel
evalVar (ThemVsMeIs rel) = evalRelation getO ThemVsMeIs rel
evalVar (ThemVsOtherIs name rel) = evalRelation getO (ThemVsOtherIs name) rel

-------------------------------------------------------------------------------

data V v = Vn Name | Vv v deriving (Eq, Ord, Read)
instance Show v => Show (V v) where
  show (Vn name) = '$' : T.unpack name
  show (Vv v) = show v
instance Parsable v => Parsable (V v) where
  parser =   try (Vv <$> parser)
         <|> try (Vn <$> (char '$' *> name))
         <?> "a variable"

-------------------------------------------------------------------------------

data Relation a
  = Equals (V a)
  | NotEquals (V a)
  | In (Set (V a))
  | NotIn (Set (V a))
  deriving (Eq, Ord)
instance Show a => Show (Relation a) where
  show (Equals v) = "=" ++ show v
  show (NotEquals v) = "≠" ++ show v
  show (In v) = "∈{" ++ List.intercalate "," (map show $ Set.toList v) ++ "}"
  show (NotIn v) = "∉{" ++ List.intercalate "," (map show $ Set.toList v) ++ "}"
instance (Ord a, Parsable a) => Parsable (Relation a) where
  parser =   try (Equals <$> (sEquals *> parser))
         <|> try (NotEquals <$> (sNotEquals *> parser))
         <|> try (In <$> (sIn *> parser))
         <|> try (NotIn <$> (sNotIn *> parser))
         <?> "a relation"

evalRelation :: Contextual a o m =>
  (V x -> m x) -> (x -> v) -> Relation x -> m (ModalFormula v)
evalRelation extract make (Equals var) = L.Var . make <$> extract var
evalRelation extract make (NotEquals var) = L.Neg <$> evalRelation extract make (Equals var)
evalRelation extract make (In vs)
  | Set.null vs = return $ L.Val False
  | otherwise = foldr1 L.Or <$> mapM (evalRelation extract make . Equals) (Set.toList vs)
evalRelation extract make (NotIn vs)
  | Set.null vs = return $ L.Val True
  | otherwise = foldr1 L.And <$> mapM (evalRelation extract make . NotEquals) (Set.toList vs)

-------------------------------------------------------------------------------

data Expr
  = Num (V Int)
  | Parens Expr
  | Add Expr Expr
  | Sub Expr Expr
  | Mul Expr Expr
  | Exp Expr Expr
  deriving Eq
instance Show Expr where
  show (Num v) = show v
  show (Parens x) = "(" ++ show x ++ ")"
  show (Add x y) = show x ++ "+" ++ show y
  show (Sub x y) = show x ++ "-" ++ show y
  show (Mul x y) = show x ++ "*" ++ show y
  show (Exp x y) = show x ++ "^" ++ show y
instance Parsable Expr where
  parser =   try (Num <$> parser)
         <|> try (parens parser)
         <|> try (Add <$> parser <*> (symbol "+" *> parser))
         <|> try (Sub <$> parser <*> (symbol "-" *> parser))
         <|> try (Mul <$> parser <*> (symbol "*" *> parser))
         <|> try (Exp <$> parser <*> (symbol "^" *> parser))
         <?> "an expression"

evalExpr :: Contextual a o m => Expr -> m Int
evalExpr (Num v) = getN v
evalExpr (Parens x) = evalExpr x
evalExpr (Add x y) = (+) <$> evalExpr x <*> evalExpr y
evalExpr (Sub x y) = (-) <$> evalExpr x <*> evalExpr y
evalExpr (Mul x y) = (*) <$> evalExpr x <*> evalExpr y
evalExpr (Exp x y) = (^) <$> evalExpr x <*> evalExpr y

-------------------------------------------------------------------------------

data Range x = REnum (V x) (Maybe (V x)) (V Int) | RList [V x] | RAll deriving Eq
instance (Enum x, Show x) => Show (Range x) where
  show (REnum sta (Just sto) ste) = case ste of
    Vv 1 -> printf "%s..%s" (show sta) (show sto)
    _    -> printf "%s..%s by %s" (show sta) (show sto) (show ste)
  show (REnum sta Nothing ste) = case ste of
    Vv 1 -> printf "%s.." (show sta)
    _    -> printf "%s.. by %s" (show sta) (show ste)
  show (RList xs) = printf "[%s]" (List.intercalate ", " $ map show xs)
  show RAll = "..."
instance (Enum x, Parsable x) => Parsable (Range x) where
  parser = try rEnum <|> try rList <|> try rAll <?> "a range" where
    rEnum = REnum <$> (parser <* symbol "..") <*> pEnumTo <*> pEnumBy
    pEnumTo = optional parser
    pEnumBy = option (Vv 1) (keyword "by" *> parser)
    rList = RList <$> parser
    rAll = symbol "..." $> RAll

elemsIn :: (Enum x, Contextual a o m) => (V x -> m x) -> Range x -> m [x]
elemsIn extract (REnum sta (Just sto) ste) = do
  start <- extract sta
  stop <- extract sto
  step <- getN ste
  return $ enumFromThenTo start (toEnum $ fromEnum start + step) stop
elemsIn extract (REnum sta Nothing ste) = do
  start <- extract sta
  step <- getN ste
  return $ enumFromThen start (toEnum $ fromEnum start + step)
elemsIn extract (RList xs) = mapM extract xs
elemsIn extract RAll = pure enumerate

-------------------------------------------------------------------------------

data Statement oa oo a o
  = Val Bool
  | Var (ModalVar (Relation oa) (Relation oo))
  | Neg (Statement oa oo a o)
  | And (Statement oa oo a o) (Statement oa oo a o)
  | Or (Statement oa oo a o) (Statement oa oo a o)
  | Imp (Statement oa oo a o) (Statement oa oo a o)
  | Iff (Statement oa oo a o) (Statement oa oo a o)
  | Consistent (V Int)
  | Provable (V Int) (Statement a o a o)
  | Possible (V Int) (Statement a o a o)
  deriving Eq

data ShowStatement = ShowStatement {
  topSymbol :: String,
  botSymbol :: String,
  notSymbol :: String,
  andSymbol :: String,
  orSymbol  :: String,
  impSymbol :: String,
  iffSymbol :: String,
  conSign :: String -> String,
  boxSign :: String-> String,
  diaSign :: String -> String,
  quotes :: (String, String) }

showFormula :: (Show oa, Show oo, Show a, Show o) =>
  ShowStatement -> Statement oa oo a o -> String
showFormula sf f = showsFormula show 0 f "" where
  showsFormula :: (Show oa, Show oo, Show o, Show a) =>
    (ModalVar (Relation oa) (Relation oo) -> String) -> Int -> Statement oa oo a o -> ShowS
  showsFormula svar p f = case f of
    Val l -> showString $ if l then topSymbol sf else botSymbol sf
    Var v -> showString $ svar v
    Neg x -> showParen (p > 8) $ showString (notSymbol sf) . showsFormula svar 8 x
    And x y -> showParen (p > 7) $ showBinary svar (andSymbol sf) 7 x 8 y
    Or  x y -> showParen (p > 6) $ showBinary svar (orSymbol sf) 6 x 7 y
    Imp x y -> showParen (p > 5) $ showBinary svar (impSymbol sf) 6 x 5 y
    Iff x y -> showParen (p > 4) $ showBinary svar (iffSymbol sf) 5 x 4 y
    Consistent v -> showString $ conSign sf (show v)
    Provable v x -> showParen (p > 8) $ quote sf $ showInner (boxSign sf) v 8 x
    Possible v x -> showParen (p > 8) $ quote sf $ showInner (diaSign sf) v 8 x
  padded o = showString " " . showString o . showString " "
  showBinary svar o l x r y = showsFormula svar l x . padded o . showsFormula svar r y
  showInner sig v i x = showString (sig $ show v) . showsFormula srelv i x
  quote sf s = let (l, r) = quotes sf in showString l . s . showString r
  srelv (MeVsThemIs v) = "Me(Them)" ++ show v
  srelv (ThemVsMeIs v) = "Them(Me)" ++ show v
  srelv (ThemVsOtherIs n v) = "Them(" ++ show n ++ ")" ++ show v

showUnicode :: (Show oa, Show oo, Show a, Show o) => Statement oa oo a o -> String
showUnicode = showFormula $ ShowStatement "⊤" "⊥" "¬" "∧" "∨" "→" "↔"
  (printf "Con(%s)")
  (\var -> if var == "0" then "□" else printf "[%s]" var)
  (\var -> if var == "0" then "◇" else printf "<%s>" var)
  ("⌜", "⌝")

showAscii :: (Show oa, Show oo, Show a, Show o) => Statement oa oo a o -> String
showAscii = showFormula $ ShowStatement "T" "F" "~" "&&" "||" "->" "<->"
  (printf "Con(%s)")
  (\var -> if var == "0" then "[]" else printf "[%s]" var)
  (\var -> if var == "0" then "<>" else printf "<%s>" var)
  ("[", "]")

instance (Show oa, Show oo, Show a, Show o) => Show (Statement oa oo a o) where
  show = showUnicode

instance (
  Ord oa, Parsable oa,
  Ord oo, Parsable oo,
  Ord a, Enum a, Parsable a,
  Ord o, Enum o, Parsable o ) => Parsable (Statement oa oo a o) where
  parser = buildExpressionParser lTable term where
    lTable =
      [ [Prefix lNeg]
      , [Infix lAnd AssocRight]
      , [Infix lOr AssocRight]
      , [Infix lImp AssocRight]
      , [Infix lIff AssocRight] ]
    term
      =   parens parser
      <|> try (constant cCon)
      <|> try (function fProvable)
      <|> try (function fPossible)
      <|> try (Var <$> relVar)
      <|> try (Val <$> val)
      <?> "A simple expression"

type ModalizedStatement a o = Statement Void Void a o

evalStatement :: Contextual a o m => ModalizedStatement a o -> m (ModalFormula (ModalVar a o))
evalStatement = evalStatement' (\v -> fail "Where did you even get this element of the Void?")

evalStatement' :: Contextual a o m =>
  (ModalVar (Relation oa) (Relation oo) -> m (ModalFormula (ModalVar a o))) ->
  Statement oa oo a o ->
  m (ModalFormula (ModalVar a o))
evalStatement' evar stm = case stm of
  Val v -> return $ L.Val v
  Var v -> evar v
  Neg x -> L.Neg <$> rec x
  And x y -> L.And <$> rec x <*> rec y
  Or x y -> L.Or <$> rec x <*> rec y
  Imp x y -> L.Imp <$> rec x <*> rec y
  Iff x y -> L.Iff <$> rec x <*> rec y
  Consistent v -> L.incon <$> getN v
  Provable v x -> L.boxk <$> getN v <*> evalStatement' evalVar x
  Possible v x -> L.diak <$> getN v <*> evalStatement' evalVar x
  where rec = evalStatement' evar

-------------------------------------------------------------------------------

data CodeFragment a o
  = ForMe Name (Range a) (CodeFragment a o)
  | ForThem Name (Range o) (CodeFragment a o)
  | ForN Name (Range Int) (CodeFragment a o)
  | LetN Name Expr
  | If (ModalizedStatement a o) (CodeFragment a o)
  | EarlyReturn (Maybe a)
  | Pass
  deriving Eq

instance (Enum a, Show a, Enum o, Show o) => Blockable (CodeFragment a o) where
  blockLines (ForMe n r c) =
    [(0, T.pack $ printf "for action %s in %s" (T.unpack n) (show r))] <>
    increaseIndent (blockLines c)
  blockLines (ForThem n r c) =
    [(0, T.pack $ printf "for outcome %s in %s" (T.unpack n) (show r))] <>
    increaseIndent (blockLines c)
  blockLines (ForN n r c) =
    [(0, T.pack $ printf "for number %s in %s" (T.unpack n) (show r))] <>
    increaseIndent (blockLines c)
  blockLines (LetN n x) =
    [(0, T.pack $ printf "let %s = %s" (T.unpack n) (show x))]
  blockLines (If s x) =
    [ (0, T.pack $ printf "if %s then" $ show s) ] <>
    increaseIndent (blockLines x)
  blockLines (EarlyReturn Nothing) = [(0, "return")]
  blockLines (EarlyReturn (Just x)) = [(0, T.pack $ printf "return %s" (show x))]
  blockLines (Pass) = [(0, "pass")]

instance (Enum a, Show a, Enum o, Show o) => Show (CodeFragment a o) where
  show = T.unpack . renderBlock

instance (
  Ord a, Enum a, Parsable a,
  Ord o, Enum o, Parsable o ) => Parsable (CodeFragment a o) where
  parser =   try fForMe
         <|> try fForThem
         <|> try fForN
         <|> try fLetN
         <|> try fIf
         <|> try (EarlyReturn <$> fReturn)
         <|> try fPass
         <?> "a code fragment"

evalCodeFragment :: Evalable a o m => CodeFragment a o -> m (ProgFrag (ModalVar a o) a)
evalCodeFragment code = case code of
  ForMe n r code -> loop (withA n) code =<< elemsIn getA r
  ForThem n r code -> loop (withO n) code =<< elemsIn getO r
  ForN n r code -> loop (withN n) code =<< elemsIn getN r
  LetN n x -> evalExpr x >>= modify . withN n >> return mPass
  If s x -> do
    cond <- evalStatement s
    ProgFrag _then <- evalCodeFragment x
    return $ ProgFrag $ \cont a ->
      (cond %^ _then cont a) %| (L.Neg cond %^ cont a)
  EarlyReturn x -> ProgFrag . const <$> evalCode (Return x)
  Pass -> return mPass
  where loop update code xs
          | null xs = return mPass
          | otherwise = foldr1 (>->) <$> sequence fragments
          where fragments = [modify (update x) >> evalCodeFragment code | x <- xs]

-------------------------------------------------------------------------------

data Code a o
  = Fragment (CodeFragment a o) (Code a o)
  | Return (Maybe a)
  deriving Eq

instance (Enum a, Show a, Enum o, Show o) => Blockable (Code a o) where
  blockLines (Fragment f c) = blockLines f ++ blockLines c
  blockLines (Return Nothing) = [(0, "return")]
  blockLines (Return (Just x)) = [(0, T.pack $ printf "return %s" (show x))]

instance (Enum a, Show a, Enum o, Show o) => Show (Code a o) where
  show = T.unpack . renderBlock

instance (Ord a, Enum a, Parsable a, Ord o, Enum o, Parsable o) => Parsable (Code a o) where
  parser =   try (Fragment <$> parser <*> parser)
         <|> try (Return <$> fReturn)
         <?> "some code"

evalCode :: Evalable a o m => Code a o -> m (Program a o)
evalCode (Fragment f cont) = evalCodeFragment f >>= \(ProgFrag p) -> p <$> evalCode cont
evalCode (Return Nothing) = evalCode (Return $ Just $ toEnum 0)
evalCode (Return (Just a)) = return $ \act -> L.Val (act == a)

codeToFormula :: (Eq a, Enum a, Enum o) => Code a o -> Either ContextError (Program a o)
codeToFormula code = runExcept $ fst <$> runStateT (evalCode code) emptyContext

-------------------------------------------------------------------------------

type VeryParsable a o = (Ord a, Enum a, Parsable a, Ord o, Enum o, Parsable o)

sEquals :: Parser ()
sEquals = void sym where
  sym =   try (symbol "=")
      <|> try (symbol "==")
      <|> try (keyword "is")
      <?> "an equality"

sNotEquals :: Parser ()
sNotEquals = void sym where
  sym =   try (symbol "≠")
      <|> try (symbol "!=")
      <|> try (symbol "/=")
      <|> try (keyword "isnt")
      <?> "a disequality"
sIn :: Parser ()
sIn = void sym where
  sym =   try (symbol "∈")
      <|> try (keyword "in")
      <?> "a membership test"
sNotIn :: Parser ()
sNotIn = void sym where
  sym =   try (symbol "∉")
      <|> try (keyword "notin")
      <?> "an absence test"

val :: Parser Bool
val = try sTop <|> try sBot <?> "a boolean value" where
  sTop = sym $> True where
    sym =   try (symbol "⊤")
        <|> try (keyword "top")
        <|> try (keyword "true")
        <|> try (keyword "True")
        <?> "truth"
  sBot = sym $> False where
    sym =   try (symbol "⊥")
        <|> try (keyword "bot")
        <|> try (keyword "bottom")
        <|> try (keyword "false")
        <|> try (keyword "False")
        <?> "falsehood"

lNeg :: Parser (Statement a b c d -> Statement a b c d)
lNeg = sym $> Neg where
  sym =   try (symbol "¬")
      <|> try (keyword "not")
      <?> "a negation"

lAnd :: Parser (Statement a b c d -> Statement a b c d -> Statement a b c d)
lAnd = sym $> And where
  sym =   try (symbol "∧")
      <|> try (symbol "/\\")
      <|> try (symbol "&")
      <|> try (symbol "&&")
      <|> try (keyword "and")
      <?> "an and"

lOr :: Parser (Statement a b c d -> Statement a b c d -> Statement a b c d)
lOr = sym $> Or where
  sym =   try (symbol "∨")
      <|> try (symbol "\\/")
      <|> try (symbol "|")
      <|> try (symbol "||")
      <|> try (keyword "and")
      <?> "an or"

lImp :: Parser (Statement a b c d -> Statement a b c d -> Statement a b c d)
lImp = sym $> Imp where
  sym =   try (symbol "→")
      <|> try (symbol "->")
      <|> try (keyword "implies")
      <?> "an implication"

lIff :: Parser (Statement a b c d -> Statement a b c d -> Statement a b c d)
lIff = sym $> Iff where
  sym =   try (symbol "↔")
      <|> try (symbol "<->")
      <|> try (keyword "iff")
      <?> "a biconditional"

constant :: Parser (V Int -> Statement a b c d) -> Parser (Statement a b c d)
constant x = x <*> option (Vv 0) parser

function :: VeryParsable c d =>
  Parser (V Int -> Statement c d c d -> Statement a b c d) ->
  Parser (Statement a b c d)
function x = x <*> option (Vv 0) parser <*> quoted parser

quoted :: Parser a -> Parser a
quoted x
  =   try (between (symbol "⌜") (symbol "⌝") x)
  <|> try (between (symbol "[") (symbol "]") x)
  <?> "something quoted"

cCon :: Parser (V Int -> Statement a b c d)
cCon = symbol "Con" $> Consistent

fProvable :: Parser (V Int -> Statement c d c d -> Statement a b c d)
fProvable = sym $> Provable where
  sym =   try (symbol "□")
      <|> try (symbol "[]")
      <|> try (symbol "Provable")
      <|> try (symbol "Box")
      <?> "a box"

fPossible :: Parser (V Int -> Statement c d c d -> Statement a b c d)
fPossible = sym $> Possible where
  sym =   try (symbol "◇")
      <|> try (symbol "<>")
      <|> try (symbol "Possible")
      <|> try (symbol "Dia")
      <|> try (symbol "Diamond")
      <?> "a diamond"

relVar :: (Ord a, Parsable a, Ord o, Parsable o) => Parser (ModalVar (Relation a) (Relation o))
relVar = try meVsThem <|> try themVsMe <|> try themVsOther <?> "a modal variable" where
  meVsThem = string "Me(Them)" *> (MeVsThemIs <$> parser)
  themVsMe = string "Them(Me)" *> (ThemVsMeIs <$> parser)
  themVsOther = string "Them(" *> (ThemVsOtherIs <$> name) <*> (char ')' *> parser)

fPass :: Parser (CodeFragment a o)
fPass = symbol "pass" $> Pass

fReturn :: Parsable a => Parser (Maybe a)
fReturn = try returnThing <|> returnNothing <?> "a return statement" where
  returnThing = Just <$> (symbol "return" *> parser)
  returnNothing = symbol "return" $> Nothing

varname :: Parser Name
varname = char '$' *> name

fLetN :: Parser (CodeFragment a o)
fLetN = LetN <$> (keyword "let" *> varname <* symbol "=") <*> parser

fIf :: VeryParsable a o => Parser (CodeFragment a o)
fIf = If <$> (keyword "if" *> parser) <*> (keyword "then" *> parser)

fForMe :: VeryParsable a o => Parser (CodeFragment a o)
fForMe = ForMe <$> (keyword "for" *> keyword "action" *> varname) <*> parser <*> parser

fForThem :: VeryParsable a o => Parser (CodeFragment a o)
fForThem = ForThem <$> (keyword "for" *> keyword "outcome" *> varname) <*> parser <*> parser

fForN :: VeryParsable a o => Parser (CodeFragment a o)
fForN = ForN <$> (keyword "for" *> keyword "number" *> varname) <*> parser <*> parser