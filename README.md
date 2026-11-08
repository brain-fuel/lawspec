

unit example.atoi_codec

itoa :: Int32 -> Text
atoi :: Text -> Int32

law "|round trip| is
  definition :
    apply law "|left inverse| atoi itoa
  end definition
  description :
    "applying {itoa} and then {atoi} recovers the original integer"
  end description
  example "|negative integers use a minus sign and round-trip unchanged| :
    x = -42
    expect itoa x = "-42"
    expect atoi (itoa x) = -42
  end example
end law
end unit

The first line defines a unit, which means three things. First, unit thing.other_thing​is a namespace header. Secondly, it's a scope, similar to the ns​ in Clojure, so other units can import​ it. Third, it's a contract boundary that the compiler understands. Each LawSpec unit​ defines laws for a certain slice of your native code.

On that note, these lines 

itoa :: Int32 -> Text
atoi :: Text -> Int32

Are declarations of functions. In LawSpec, they are called *adapters*.

We should understand the distinction between declaration and definition. You declare a function when you write its signature, meaning name, domain, and codomain. This being software, domain and codomain are defined in terms of types. By contrast, a definition gives you the function body, which tells you what it actually does.

The "actually does" part is your native code. Logically, this means that the function body is your native code. The declarations given in LawSpec, therefore, are references to functions implemented in Python or Elixir or Rust or whatever language you use. Constraining something outside of the LawSpec code means that we need some reference thereto, but cannot define it inside the LawSpec code.

## Law Definitions

We don't define functions, but we do define laws. Definitions of laws in LawSpec are given by – shocker – definition​. The definition​ keyword is, literally, how LawSpec creates definitions, so the correspondence is disquotational: every law has a definition​ because every law has a definition. A close look at the definition will tell us what functions are being constrained and how, because the definition​ uses declared laws (e.g. itoa​, atoi​) and places them in LawSpec expressions that ascribe properties thereto. Any functions (adapters) constrained by a law's definition​ must be reachable from the current unit. These cannot be imported 
