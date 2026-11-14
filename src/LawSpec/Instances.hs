-- | The operations of the built-in capability instances, as a built-in unit,
-- lawspec.instances, added to a program that imports it. Each is an ordinary
-- structurally recursive definition: the meaning of the operation that the
-- targets run natively, and what a proof about it unfolds.
-- ref:DEC-capability-instances
module LawSpec.Instances
  ( instancesUnit, instancesSource, instanceLawsUnit, instanceLawsSource
  ) where

instancesUnit :: String
instancesUnit = "lawspec.instances"

instancesSource :: String
instancesSource = unlines
  [ "unit " ++ instancesUnit
  , "-- Mappable List: prelude.map."
  , "function mapList (f :: a -> b) (xs :: List a) -> List b is"
  , "  first matching case of xs:"
  , "    when Nil then []"
  , "    when Cons x rest then Cons (f x) (mapList f rest)"
  , "  end case"
  , "end function"
  , ""
  , "-- Mappable (Either e): prelude.map over the success value."
  , "function mapEither (f :: a -> b) (value :: Either e a) -> Either e b is"
  , "  first matching case of value:"
  , "    when Left failure then Left failure"
  , "    when Right x then Right (f x)"
  , "  end case"
  , "end function"
  , ""
  , "-- Filterable List: prelude.filter."
  , "function filterList (keep :: a -> Bool) (xs :: List a) -> List a is"
  , "  first matching case of xs:"
  , "    when Nil then []"
  , "    when Cons x rest then"
  , "      if keep x then Cons x (filterList keep rest) else filterList keep rest end if"
  , "  end case"
  , "end function"
  , ""
  , "-- Foldable List: prelude.foldLeft, prelude.foldRight, prelude.all,"
  , "-- prelude.any and prelude.length."
  , "function foldLeftList (step :: b -> a -> b) (initial :: b) (xs :: List a) -> b is"
  , "  first matching case of xs:"
  , "    when Nil then initial"
  , "    when Cons x rest then foldLeftList step (step initial x) rest"
  , "  end case"
  , "end function"
  , ""
  , "function foldRightList (step :: a -> b -> b) (initial :: b) (xs :: List a) -> b is"
  , "  first matching case of xs:"
  , "    when Nil then initial"
  , "    when Cons x rest then step x (foldRightList step initial rest)"
  , "  end case"
  , "end function"
  , ""
  , "function allList (holds :: a -> Bool) (xs :: List a) -> Bool is"
  , "  first matching case of xs:"
  , "    when Nil then true"
  , "    when Cons x rest then holds x and allList holds rest"
  , "  end case"
  , "end function"
  , ""
  , "function anyList (holds :: a -> Bool) (xs :: List a) -> Bool is"
  , "  first matching case of xs:"
  , "    when Nil then false"
  , "    when Cons x rest then holds x or anyList holds rest"
  , "  end case"
  , "end function"
  , ""
  , "function lengthList (xs :: List a) -> Integer is"
  , "  first matching case of xs:"
  , "    when Nil then 0"
  , "    when Cons x rest then 1 + lengthList rest"
  , "  end case"
  , "end function"
  , ""
  , "-- Appendable (List a): ++, and prelude.concat by folding it."
  , "function appendList (xs :: List a) (ys :: List a) -> List a is"
  , "  first matching case of xs:"
  , "    when Nil then ys"
  , "    when Cons x rest then Cons x (appendList rest ys)"
  , "  end case"
  , "end function"
  , ""
  , "function concatList (xss :: List (List a)) -> List a is"
  , "  first matching case of xss:"
  , "    when Nil then []"
  , "    when Cons xs rest then appendList xs (concatList rest)"
  , "  end case"
  , "end function"
  , "end unit"
  ]

-- | The laws of the capabilities, stated once for the built-in instances
-- over functions of which nothing is known (first, second, accepts,
-- alsoAccepts, combine: adapters of this unit, which the solver leaves
-- uninterpreted, and only here). LawSpec's own checks prove each; a proof
-- then holds for whatever function a spec writes in their place.
-- ref:DEC-capability-laws
instanceLawsUnit :: String
instanceLawsUnit = "lawspec.instances.laws"

instanceLawsSource :: String
instanceLawsSource = unlines (
  [ "unit " ++ instanceLawsUnit
  , "first :: Integer -> Integer"
  , "second :: Integer -> Integer"
  , "accepts :: Integer -> Bool"
  , "alsoAccepts :: Integer -> Bool"
  , "combine :: Integer -> Integer -> Integer"
  , "partial :: Integer -> Either Integer Integer"
  , ""
  , "function same (n :: Integer) -> Integer is n end function"
  , "function negated (b :: Bool) -> Bool is not b end function"
  , "" ] ++
  concat
  [ -- Mappable List
    law "map of the identity changes nothing" ["xs"] "prelude.map same xs = xs"
  , law "map of a composition is two maps" ["xs"] "prelude.map second (prelude.map first xs) = prelude.map (second . first) xs"
    -- Mappable (Either e)
  , [ "law \"|map over an Either of the identity changes nothing| is definition:"
    , "  for all (n :: Integer) => prelude.map same (partial n) = partial n end for all"
    , "end definition end law"
    , "law \"|map over an Either of a composition is two maps| is definition:"
    , "  for all (n :: Integer) => prelude.map second (prelude.map first (partial n)) = prelude.map (second . first) (partial n) end for all"
    , "end definition end law" ]
    -- Filterable List
  , law "filter keeps only what is accepted" ["xs"] "prelude.all accepts (prelude.filter accepts xs)"
  , law "filter never lengthens" ["xs"] "prelude.length (prelude.filter accepts xs) <= prelude.length xs"
  , law "filters commute" ["xs"] "prelude.filter accepts (prelude.filter alsoAccepts xs) = prelude.filter alsoAccepts (prelude.filter accepts xs)"
  , law "filter of what is all accepted changes nothing" ["xs"] "prelude.all accepts xs implies prelude.filter accepts xs = xs"
    -- Foldable List
  , law "length is never negative" ["xs"] "prelude.length xs >= 0"
  , law "all and any are dual" ["xs"] "if prelude.any accepts xs then not prelude.all (negated . accepts) xs else prelude.all (negated . accepts) xs end if"
    -- Appendable (List a)
  , law "appending nothing changes nothing" ["xs"] "xs ++ [] = xs and [] ++ xs = xs"
  , law "append associates" ["xs", "ys", "zs"] "(xs ++ ys) ++ zs = xs ++ (ys ++ zs)"
  , law "length of an append is the sum" ["xs", "ys"] "prelude.length (xs ++ ys) = prelude.length xs + prelude.length ys"
    -- How the operations meet
  , law "map keeps the length" ["xs"] "prelude.length (prelude.map first xs) = prelude.length xs"
  , law "map distributes over append" ["xs", "ys"] "prelude.map first (xs ++ ys) = prelude.map first xs ++ prelude.map first ys"
  , law "filter distributes over append" ["xs", "ys"] "prelude.filter accepts (xs ++ ys) = prelude.filter accepts xs ++ prelude.filter accepts ys"
  , law "all of an append is all of both" ["xs", "ys"] "prelude.all accepts (xs ++ ys) = (prelude.all accepts xs and prelude.all accepts ys)"
  , law "a right fold of an append folds the second first" ["start", "xs", "ys"]
      "prelude.foldRight combine start (xs ++ ys) = prelude.foldRight combine (prelude.foldRight combine start ys) xs"
  , law "a left fold of an append folds the first first" ["start", "xs", "ys"]
      "prelude.foldLeft combine start (xs ++ ys) = prelude.foldLeft combine (prelude.foldLeft combine start xs) ys"
  , law "filter after map is map after filter" ["xs"]
      "prelude.filter accepts (prelude.map first xs) = prelude.map first (prelude.filter (accepts . first) xs)" ] ++
  [ "", "harness " ++ instanceLawsUnit ++ ".proofs for " ++ instanceLawsUnit ++ " is" ] ++
  concat [ [ "  for law \"|" ++ name ++ "|", "    prove by induction on xs", "  end for law" ]
         | name <- [ "append associates", "length of an append is the sum", "map distributes over append"
                   , "filter distributes over append", "all of an append is all of both"
                   , "a right fold of an append folds the second first", "a left fold of an append folds the first first" ] ] ++
  [ "end harness", "end unit" ])
  where
    law name inputs body =
      [ "law \"|" ++ name ++ "| is definition:"
      , "  for all " ++ unwords [ "(" ++ i ++ " :: " ++ (if i == "start" then "Integer" else "List Integer") ++ ")" | i <- inputs ] ++ " =>"
      , "    " ++ body
      , "  end for all"
      , "end definition end law" ]
