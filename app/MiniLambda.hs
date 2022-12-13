{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonoLocalBinds #-}
module MiniLambda where
import Data.Map (Map, empty, (!), insert, union, toList, lookup, member, delete, map)
import Effectful
import Control.Monad.Memo

import Util
import Data.Bifunctor
import Control.Monad
import Data.Maybe
import Data.List ((++), sort)
import Data.Char
import Text.Parsec
import Data.Vector hiding ((++))
import Control.Monad.IO.Class
import Data.Hashable
import GHC.Generics (Generic)

data VarRef = Name String | Paralell Int deriving (Eq, Generic, Hashable)

data MiniLambda = 
    App MiniLambda MiniLambda
    |Abs String MiniLambda
    |Var VarRef
    |Pi String MiniLambda MiniLambda deriving (Eq, Generic, Hashable)

instance Show MiniLambda where
    show (App x y) = "(" ++ show x ++ " " ++ show y ++ ")"
    show (Abs name y) = "(λ" ++ name ++ "." ++ (show y) ++ ")"
    show (Var (Name x)) = x
    show (Var (Paralell x)) = "[" ++ (show x) ++ "]"
    show (Pi name type' body) = "Π" ++ " (" ++ name ++ ":" ++ show type' ++ ")." ++ show body

type TreeType = MiniLambda
type Term = (TreeType, TreeType)
type Clause = (String, TreeType)
data SearchAST = SearchAST TreeType (Vector Clause) deriving Show

data Problem = Problem SearchAST (Maybe Term)

instance Show Problem where
    show (Problem (SearchAST goal _) (Just (term, type_))) = show term ++ " : " ++ show type_ ++ " goal : " ++ show goal ++ "\n"
    show (Problem (SearchAST goal _) Nothing) = " ? " ++  "goal : " ++ show goal ++ "\n"

type Rules = TreeType -> Maybe Problem

type SetProblems = Map Int Problem
type SetTypes = Map Int Int
data Nodes = Nodes (SetProblems) (SetTypes)

instance Show Nodes where
    show (Nodes problems _) = format $ Data.Map.toList problems
       where
        format ((k, x) : xs) = show k ++ " = " ++ show x ++ "\n" ++ format xs
        format [] = "\n"


consumeRef :: Parsec String st String
consumeRef = many1 alphaNum

consumePiType :: Parsec String st TreeType
consumePiType = do
    string ("[")
    string "("
    param <- consumeRef
    spaces
    string ":"
    spaces
    type_ <- consumeMiniLambda
    spaces
    string ")"
    spaces
    string "->"
    spaces
    body <- consumeMiniLambda
    string ("]")
    return (Pi param type_ body)

parseTypeNotation :: Parsec String st TreeType
parseTypeNotation = try (consumePiType) <|> consumeMiniLambda

consumeVar :: Parsec String st MiniLambda
consumeVar = do
    var <- consumeRef
    return (Var (Name var))

consumeAbs :: Parsec String st MiniLambda
consumeAbs = do
    string "\\"
    ref <- consumeRef
    spaces
    string "=>"
    spaces
    body <- consumeMiniLambda
    return (Abs ref body)

consumeApp :: Parsec String st MiniLambda
consumeApp = do
    string "("
    x <- consumeMiniLambda
    many1 space
    y <- consumeMiniLambda
    string ")"
    return (App x y)

consumeMiniLambda :: Parsec String st MiniLambda
consumeMiniLambda = choice [consumeApp, consumePiType, consumeAbs, consumeVar]

parseDeclarations :: Parsec String st (String, TreeType)
parseDeclarations = do
    name <- consumeRef
    spaces
    string "="
    spaces
    lamdba_expr <- parseTypeNotation
    return (name, lamdba_expr)

parseBlock :: Parsec String st SearchAST
parseBlock = do
    x <- many parseStatement
    string ":"
    spaces
    goal_term <- parseTypeNotation
    return (SearchAST goal_term (Data.Vector.fromList x))
  where 
    parseStatement = do
        decl <- parseDeclarations
        many1 (char '\n')
        return decl

data GraphNodes = Link Int (Map Int GraphNodes) | Null

-- insertOnGraph :: (Int, Int) -> GraphNodes -> GraphNodes
-- insertOnGraph (parent, key) (Link p childrens@(x : xs)) 
--     |p == parent = Link p (Link key [] : childrens)
--     |otherwise = insertOnGraph (parent, key) x
-- insertOnGraph (parent, key) Null = Link key []

-- merge :: GraphNodes -> GraphNodes -> GraphNodes
-- merge (Link p xs) (Link p' xs') = Link p (check_diff xs xs')
--   where
--     check_diff ((Link p xs) : graph) ((Link p' xs') : graph') = 
--         if p == p' then
--             (Link p (check_diff xs xs')) : graph
--         else 
--             (Link p (check_diff xs xs')) : check_diff graph ((Link p' xs') : graph')
-- merge v Null = v

type SearchStrategy = GraphNodes

type USearch a = Nodes -> Map String Rules -> SearchStrategy -> IO (a, Nodes, Map String Rules, SearchStrategy)

newtype Search a = Wrap (USearch a)

instance Functor Search where
  fmap f (Wrap serch_a) = Wrap (\nodes rules struct -> do
     (a, nodes', rules', struct') <- serch_a nodes rules struct
     return (f a, nodes', rules', struct'))

unique :: a -> USearch a
unique k nodes rules struct = return (k, nodes, rules, struct)

instance Applicative Search where
  pure a = Wrap (unique a)
  (<*>) (Wrap fab) (Wrap search_a) = Wrap (\nodes rules struct -> do
    (a, nodes', rules', struct') <- search_a nodes rules struct
    (ab, nodes'', rules'', struct'') <- fab nodes' rules' struct'
    return (ab a, nodes'', rules'', struct''))

bind  :: forall a b. USearch a -> (a -> USearch b) -> USearch b
bind k f (Nodes nodes types) rules struct = do
   (a, (Nodes nodes' types'), rules', struct') <- k (Nodes nodes types) rules struct
   f a (Nodes (Data.Map.union nodes' nodes) (Data.Map.union types' types)) (Data.Map.union rules' rules) struct'

instance Monad Search where
  (>>=) (Wrap search_a) f = Wrap (bind search_a (\a -> do
    let (Wrap search) = f a
    search
   ))

instance MonadIO Search where
    liftIO io = Wrap (\nodes map struct -> io >>= return . (, nodes, map, struct))

saveNode :: (Int, Problem) -> Search ()
saveNode (k, x) = Wrap (\nodes@(Nodes map types) rules struct -> return ((), Nodes (Data.Map.insert k x map) types, rules, struct))

saveTypePath :: (Int, Int) -> Search ()
saveTypePath (k, x) = Wrap (\nodes@(Nodes map types) rules struct -> return ((), Nodes map (Data.Map.insert k x types), rules, struct))

getNode :: Int -> Search Problem
getNode k = Wrap (\nodes@(Nodes map types) rules struct -> return (map Data.Map.! k, nodes, rules, struct))

checkNode :: Int -> Search Bool
checkNode k = Wrap (\nodes@(Nodes map types) rules struct -> return (member k map, nodes, rules, struct))

getGoal :: Problem -> TreeType
getGoal (Problem (SearchAST goal _) _) = goal

get_safe_node :: Int -> Search (Maybe Problem)
get_safe_node k = Wrap (\nodes@(Nodes map types) rules struct -> return (Data.Map.lookup k map, nodes, rules, struct))

createProblem :: TreeType -> Vector Clause -> Search Int
createProblem goal clauses = do
    let ast = SearchAST goal clauses
    startNode ast

pushNode :: Problem -> Search Int
pushNode problem@(Problem ast term) = do
    let key = generateHashContext ast
    -- let hash_node = hash $ getGoal problem
    check <- checkNode key
    if check then
        return key
    else do
        saveNode (key, problem)
        -- saveTypePath (hash_node, key)
        return key

updateNode :: Int -> Problem -> Search Int
updateNode key problem = do
    n <- liftIO $ randIO (0, 999999)
    saveNode (key, problem)
    return n

mapNode :: Int -> (Problem -> Problem) -> Search ()
mapNode key f = do
    node <- getNode key
    void $ updateNode key (f node)

getTerm :: Problem -> Maybe Term
getTerm (Problem ast term) = term

extendContext :: (String, TreeType) -> Problem -> Problem
extendContext (name, type') (Problem (SearchAST goal context) term) = 
    Problem (SearchAST goal (cons (name, type') context)) term

setTerm :: Int -> Term -> Search ()
setTerm k term = do
    (Problem ast term') <- getNode k
    saveNode (k, Problem ast (Just term))

getNodes :: Search Nodes
getNodes = Wrap (\nodes@(Nodes map types) rules struct -> return (nodes, nodes, rules, struct))

killNode :: Int -> Search ()
killNode k = Wrap (\nodes@(Nodes map types) rules struct -> return ((), (Nodes (delete k map) types), rules, struct))


getProblems :: Search [(Int, Problem)]
getProblems = do
    (Nodes nodes types) <- getNodes
    return $ Data.Map.toList nodes

generateHashContext :: SearchAST -> Int
generateHashContext (SearchAST goal clauses) = do
    let hash_clauses = Data.Vector.map (hash . snd) clauses
    let sorted_hashes = Data.List.sort (Data.Vector.toList hash_clauses)
    hash (hash goal : sorted_hashes)

selectOnePertubation :: Vector a -> Search (Maybe a)
selectOnePertubation as
    |Data.Vector.null as = return Nothing
    |otherwise = do
        r <- liftIO $ randIO (0, (Data.Vector.length $ as) - 1)
        return $ Just $ as Data.Vector.! r

isReductible :: TreeType -> TreeType -> Bool 
isReductible v (Pi _ type_ _) = v == type_
isReductible _ _ = False

searchPiReductible :: TreeType -> SearchAST -> (Vector Clause) 
searchPiReductible term (SearchAST _ vec) = Data.Vector.filter (isReductible term . snd) vec

filterHeadByType :: TreeType -> TreeType -> Bool 
filterHeadByType v@(Var _) v'@(Var _) = v == v'
filterHeadByType v (Pi _ type_ _) = v == type_
filterHeadByType t t' = t == t'

isEqualType :: TreeType -> TreeType -> Search Bool
isEqualType (Var (Paralell k)) term' = do
    term <- getTerm <$> getNode k
    case term of {
        Just (expr, term) -> isEqualType expr term';
        Nothing -> return $ (Var (Paralell k)) == term';
    }
isEqualType term' (Var (Paralell k)) = do
    term <- getTerm <$> getNode k
    case term of {
        Just (expr, term) -> isEqualType term' expr;
        Nothing -> return $ term' == (Var (Paralell k));
    }
isEqualType (App x y) (App x' y') = do
    b_x <- isEqualType x x'
    b_y <- isEqualType y y'
    return (b_x && b_y)
isEqualType (Abs name body) (Abs name' body') = do
    body <- (substitute (Var $ Name name, Var $ Name name') body)
    isEqualType body body'
isEqualType v v' = return $ v == v'

isEqualTailPi :: TreeType -> TreeType -> Search Bool 
isEqualTailPi final_type pi'@(Pi _ _ _) = isEqualType final_type $ getPiFinalType pi'
isEqualTailPi t t' = isEqualType t t'

selectReachablePi :: TreeType -> Vector (a, TreeType) -> Search (Vector (a, TreeType))
selectReachablePi term vec = Data.Vector.filterM (isEqualTailPi term . snd) vec

piToList :: MiniLambda -> [MiniLambda]
piToList pi = go pi []
  where 
    go pi@(Pi name _ body) ls = go body (pi : ls)
    go _ ls = ls
    
-- selectDerivableFuncs :: TreeType -> SearchAST -> (Vector Clause) 
selectDerivableFuncs :: MiniLambda -> Vector (a, MiniLambda) -> [((a, MiniLambda), [(Maybe MiniLambda, MiniLambda)])]
selectDerivableFuncs param vec = do
    Data.Vector.foldl selectPiTypes [] vec
    where
        selectPiTypes ls all@(_, pi@(Pi name _ body)) = do
            let param_equality = Prelude.map (\target -> (if filterHeadByType param target then Just param else Nothing, target)) (piToList pi)
            if Prelude.any (isJust . fst) param_equality
                then (all, param_equality) : ls
            else ls
        selectPiTypes ls _ = ls

betaExpand :: SearchAST -> Int -> Search Problem
betaExpand ast@(SearchAST pi@(Pi name pi_type body) clauses) key = do
    node_id <- createProblem body clauses
    mapNode node_id (extendContext (name, pi_type))
    return (Problem ast (Just (Abs name (Var $ Paralell node_id), pi)))

selectClauseByEmptyState :: Clause -> SearchAST -> Search Problem
selectClauseByEmptyState (name_term, type_@(Pi _ _ _)) ast@(SearchAST goal clauses) = do
    -- term <- constructPartialApplication type_
    return (Problem ast (Just (Var $ Name name_term, type_)))
--   where
--     constructPartialApplication (Pi _ type_ body) = do
--         rec_ <- constructPartialApplication body
--         node_id <- createProblem type_ clauses
--         return $ App rec_ (Var $ Paralell node_id)
--     constructPartialApplication _ = return $ Var (Name name_term)

selectClauseByEmptyState (name_term, type_) ast@(SearchAST goal clauses) = do
    return (Problem ast (Just (Var (Name name_term), type_)))

substitute :: (MiniLambda, MiniLambda) -> MiniLambda -> Search MiniLambda
substitute params (App func body) = do
    func <- (substitute params func) 
    body <- (substitute params body)
    return $ App func body
substitute params (Abs name body) = do
    body <- substitute params body
    return $ Abs name $ body
substitute params (Pi name type_ body) = do
    type_ <- (substitute params type_)
    body <- (substitute params body)
    return $ Pi name type_ body
substitute (origin, term) v@(Var (Paralell target)) = do
    type_ <- getTerm <$> (getNode target)
    case type_ of {
        Just (term, type_) -> (do
            map <- (substitute (origin, term) term)
            setTerm target (map, type_)
            return v   
        );
        Nothing -> return v;
    }
substitute (origin, term) v = return $ if origin == v then term else v

getPiFinalType :: TreeType -> TreeType
getPiFinalType (Pi _ _ body) = getPiFinalType body
getPiFinalType v = v

getPiHeadType :: TreeType -> TreeType
getPiHeadType (Pi _ type_ body) = type_
getPiHeadType _ = error "Not a pi type applied on getPiHeadType"

mapTermClauses :: Vector Clause -> (TreeType -> TreeType) -> Vector Clause
mapTermClauses vec f = Data.Vector.map (second f) vec

piHeadReduction :: Problem -> Search (Maybe Problem)
piHeadReduction (Problem (SearchAST goal clauses) (Just (expr, Pi name type_ body))) = do
    node_id <- createProblem type_ clauses
    subs_type <- substitute (Var $ Name name, Var $ Paralell node_id) body
    goal_type <- substitute (Var $ Name name, Var $ Paralell node_id) goal
    return (Just (Problem (SearchAST goal_type clauses) (Just ((App expr $ Var $ Paralell node_id), subs_type))))

expandPiReduction :: Problem -> Search (Maybe Problem)
expandPiReduction  (Problem ast@(SearchAST goal clauses) (Just (expr, type_))) = do
    clausesCompatible <- selectReachablePi goal clauses
    liftIO $ print (goal, clausesCompatible)
    clause <- selectOnePertubation . fromList . selectDerivableFuncs type_ $ clausesCompatible
    case clause of {
        Just (clause, piConstruction) -> (do
            -- let ((name, term), param_pos) = (fst clause, fromJust . snd $ clause)
            (regex, term) <- constructParallelFunc piConstruction (Var $ Name $ fst clause)
            type' <- case regex of {
                Just regex -> substitute (regex, expr) $ getPiFinalType $ snd clause;
                Nothing -> return $ getPiFinalType $ snd clause;
            }
            return . Just $ Problem ast (Just (term, type'))
        );
        Nothing -> return Nothing;
    }
  where
    constructParallelFunc (pi : pi' : xs) base_case = do
        (regex', rec_) <- constructParallelFunc (pi' : xs) base_case
        (regex, param) <- constructParam pi
        return (Util.or regex regex', (App param rec_))
    constructParallelFunc (pi : []) base_case = do
        (regex, param) <- constructParam pi 
        return (regex, App base_case param)
    constructParam (Just complete_param, _) = return (Just complete_param, expr)
    constructParam (Nothing, type_) = do
        node_id <- createProblem (getPiHeadType type_) clauses
        return $ (Nothing, Var $ Paralell node_id)

tryFirstTerm :: Problem -> Search Problem
tryFirstTerm (Problem ast@(SearchAST goal clauses) _) = do
    reachableClauses <- selectReachablePi goal clauses
    clause <- selectOnePertubation $ reachableClauses
    -- clause <- selectOnePertubation clauses
    case clause of {
        Just clause -> selectClauseByEmptyState clause ast;
        Nothing -> do
            probably_bad_typed_clause <- selectOnePertubation clauses
            case probably_bad_typed_clause of {
                Just clause -> selectClauseByEmptyState clause ast;
                Nothing -> return (Problem ast Nothing)
            }
    }

exploreProblem :: Problem -> Int -> Search (Maybe Problem)
exploreProblem problem@(Problem ast@(SearchAST pi@(Pi _ _ _) _) Nothing) key = do
    Just <$> (betaExpand ast key)
exploreProblem problem@(Problem ast Nothing) key = do
    Just <$> (tryFirstTerm problem)
exploreProblem problem@(Problem ast (Just (expr, Pi _ _ _))) key = piHeadReduction problem
exploreProblem problem@(Problem ast (Just _)) key = return Nothing


simplifyNodes :: Int -> Search (Maybe MiniLambda)
simplifyNodes key = do
    node <- getNode key
    case node of {
        (Problem (SearchAST goal decls) Nothing) -> return Nothing;
        (Problem (SearchAST goal decls) (Just (term, type'))) -> do
            simplified_term <- simplifyTerm term
            simplified_type' <- simplifyTerm type'
            setTerm key (simplified_term, simplified_type')
            return (Just simplified_term)
    }
    where
        simplifyTerm (App x y) = do
            x <- simplifyTerm x
            y <- simplifyTerm y
            return (App x y)
        simplifyTerm (Abs name body) = do
            body <- simplifyTerm body
            return (Abs name body)
        simplifyTerm (Pi name type' body) = do
            type' <- simplifyTerm type'
            body <- simplifyTerm body
            return (Pi name type' body)
        simplifyTerm v@(Var (Paralell key)) = do
            term <- simplifyNodes key
            case term of {
                Just x -> return x;
                Nothing -> return v;
            }
        simplifyTerm v = return v


startNode :: SearchAST -> Search Int
startNode ast@(SearchAST goal decls) = pushNode $ Problem ast Nothing

checkIfReachGoal :: Problem -> Bool
checkIfReachGoal (Problem (SearchAST goal _) (Just (_, type'))) = goal == type'
checkIfReachGoal _ = False

iterateSolutions :: [(Int, Problem)] -> Search ()
iterateSolutions [] = return ()
iterateSolutions ((key, p@(Problem _ _)) : ps) = do
    if checkIfReachGoal p then
        return ()
    else do
        problem <- exploreProblem p key
        case problem of {
            Just x -> void $ updateNode key x;
            Nothing -> return ()
         }
    iterateSolutions ps

search :: Search ()
search = getProblems >>= iterateSolutions

iterateSearch :: Int -> Search ()
iterateSearch 0 = return ()
iterateSearch n = do
    search
    iterateSearch (n - 1)

searchSolution :: SearchAST -> Search MiniLambda
searchSolution ast = do
    node_genisis <- startNode ast
    iterateSearch 200
    let (WrapMemo memo) = constructLambdaTerm node_genisis 
    (term, _) <- memo Data.Map.empty 
    return term


type Memo m a = Monad m => (Map Int MiniLambda) -> m (a, (Map Int MiniLambda))

newtype WrapMemo m a = WrapMemo (MiniLambda.Memo m a)

instance Monad m => Functor (WrapMemo m) where
  fmap f (WrapMemo memo) = WrapMemo $ \map -> do
       (a, map') <- memo map
       return (f a, map')

instance Monad m => Applicative (WrapMemo m) where
    pure x = WrapMemo $ \map -> return (x, map)
    (<*>) = (<*>) 

instance Monad m => Monad (WrapMemo m) where
    (>>=) (WrapMemo memo) f = WrapMemo $ \map -> do
        (a, map') <- memo map
        let (WrapMemo memo') = f a
        (b, map'') <- memo' map'
        return (b, Data.Map.union map' map'')

liftM' :: m a -> WrapMemo m a
liftM' a = WrapMemo $ \map -> (, Data.Map.empty) <$> a

memoNode :: Int -> MiniLambda -> WrapMemo m ()
memoNode k v = WrapMemo $ \map -> return ((), Data.Map.insert k v map)

remember :: Int -> WrapMemo m (Maybe MiniLambda)
remember k = WrapMemo $ \map -> do
     return (Data.Map.lookup k map, map)

constructLambdaTerm :: Int -> WrapMemo Search MiniLambda
constructLambdaTerm k = do
    node <- liftM' $ getNode k
    r <- remember k
    liftM' $ liftIO $ print (k, r, getTerm node)
    case (getTerm node) of {
        Just (term, type_) -> (do
               term <- readTerm term
               memoNode k term
               return term
            );
        Nothing -> return $ Var (Name "?")
    }
    where
        readTerm (App x y) = do
            x <- readTerm x
            y <- readTerm y
            return $ App x y
        readTerm (Abs name body) = do
            body <- readTerm body
            return $ Abs name body
        readTerm (Pi name type_ body) = do
            type_ <- readTerm type_
            body <- readTerm body
            return $ Pi name type_ body
        readTerm v@(Var (Name m)) = return v
        readTerm (Var (Paralell p)) = do
            r <- remember p
            case r of {
                Just term -> return term;
                Nothing -> constructLambdaTerm p;
            }
            
        

readMiniLambda :: String -> Either ParseError (IO [Char])
readMiniLambda str = do
    case (parse parseBlock "" str) of {
        Left x -> Left x;
        Right ast -> return $ do
            let (Wrap r) = searchSolution ast
            (a, nodes, map, strategy) <- r (Nodes Data.Map.empty Data.Map.empty) Data.Map.empty Null
            return (show a ++ "\n" ++ show nodes)
    }