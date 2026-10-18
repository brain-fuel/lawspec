namespace Example;
using LawSpec.Data;
public static class Gadt { public static string Describe(Shown value) => value.witness; }
