package example
import java.math.BigInteger
@groovy.transform.CompileStatic
class Algebra {
 static Number add(BigInteger x,BigInteger y){return x.add(y);}
 static Number multiply(BigInteger x,BigInteger y){return x.multiply(y);}
 static Number negateValue(BigInteger x){return x.negate();}
 static Number maximumValue(BigInteger x,BigInteger y){return x.max(y);}
 static Number subtractValue(BigInteger x,BigInteger y){return x.subtract(y);}
 static Number divideLeft(BigInteger x,BigInteger y){return x.subtract(y);}
 static Number divideRight(BigInteger x,BigInteger y){return x.add(y);}
}