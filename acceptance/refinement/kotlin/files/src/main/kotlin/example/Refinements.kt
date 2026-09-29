package example
object Refinements { fun add(a:Byte,b:Byte):Number=a.toInt()+b.toInt(); fun successor(a:Byte):Number=a.toInt()+1; fun count(a:String):Number=a.codePointCount(0,a.length); fun preserve(a:java.math.BigInteger):Number=a; fun positive(a:Byte):Byte=a; fun abstractEcho(a:java.math.BigInteger):Number=a }
