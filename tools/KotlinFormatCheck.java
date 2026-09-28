// Development-only checks using the independently installed Kotlin parser.
import com.intellij.openapi.util.Disposer;
import com.intellij.psi.PsiComment;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiErrorElement;
import com.intellij.psi.PsiWhiteSpace;
import com.intellij.psi.util.PsiTreeUtil;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles;
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment;
import org.jetbrains.kotlin.config.CompilerConfiguration;
import org.jetbrains.kotlin.psi.KtBinaryExpression;
import org.jetbrains.kotlin.psi.KtBlockExpression;
import org.jetbrains.kotlin.psi.KtClassBody;
import org.jetbrains.kotlin.psi.KtFunctionLiteral;
import org.jetbrains.kotlin.psi.KtIfExpression;
import org.jetbrains.kotlin.psi.KtLoopExpression;
import org.jetbrains.kotlin.psi.KtNamedFunction;
import org.jetbrains.kotlin.psi.KtParameterList;
import org.jetbrains.kotlin.psi.KtPsiFactory;
import org.jetbrains.kotlin.psi.KtValueArgumentList;
import org.jetbrains.kotlin.psi.KtWhenEntry;
import org.jetbrains.kotlin.psi.KtWhenExpression;

public final class KotlinFormatCheck {
  private static String tree(PsiElement element) {
    if (element instanceof PsiWhiteSpace || element instanceof PsiComment) return "";
    var kind = element.getNode().getElementType().toString();
    if (kind.equals("SEMICOLON")) return "";
    if (kind.equals("COMMA")) {
      var next = element.getNextSibling();
      while (next instanceof PsiWhiteSpace || next instanceof PsiComment)
        next = next.getNextSibling();
      if (next != null
          && List.of("RPAR", "RBRACKET", "GT").contains(next.getNode().getElementType().toString()))
        return "";
    }
    // getChildren omits punctuation; visit AST children to retain operators,
    // declaration modifiers, string-template fragments and type arguments.
    var result = new StringBuilder(kind).append('(');
    var child = element.getFirstChild();
    if (child == null)
      result.append(element.getText().length()).append(':').append(element.getText());
    while (child != null) {
      result.append(tree(child));
      child = child.getNextSibling();
    }
    return result.append(')').toString();
  }

  private record Indent(int line, int base, int end) {}

  private static List<Indent> indents(PsiElement file, String source) {
    var result = new ArrayList<Indent>();
    var document = new ArrayList<Integer>();
    document.add(0);
    for (int i = 0; i < source.length(); i++) if (source.charAt(i) == '\n') document.add(i + 1);
    java.util.function.IntUnaryOperator lineAt =
        offset -> {
          int found = java.util.Collections.binarySearch(document, offset);
          return found >= 0 ? found : -found - 2;
        };
    for (var owner :
        PsiTreeUtil.collectElements(
            file,
            element ->
                element instanceof KtBlockExpression
                    || element instanceof KtClassBody
                    || element instanceof KtWhenExpression
                    || element instanceof KtParameterList
                    || element instanceof KtValueArgumentList)) {
      PsiElement brace;
      List<? extends PsiElement> children;
      if (owner instanceof KtBlockExpression block) {
        brace = block.getLBrace();
        if (brace == null && block.getParent() instanceof KtFunctionLiteral lambda)
          brace = lambda.getLBrace();
        children = block.getStatements();
      } else if (owner instanceof KtClassBody body) {
        brace = body.getLBrace();
        children = body.getDeclarations();
      } else if (owner instanceof KtParameterList parameters) {
        brace = parameters.getFirstChild();
        children = parameters.getParameters();
      } else if (owner instanceof KtValueArgumentList arguments) {
        brace = arguments.getFirstChild();
        children = arguments.getArguments();
      } else {
        var expression = (KtWhenExpression) owner;
        brace = expression.getOpenBrace();
        children = expression.getEntries();
      }
      if (brace == null) continue;
      var members = new ArrayList<PsiElement>(children);
      if (owner instanceof KtBlockExpression
          || owner instanceof KtClassBody
          || owner instanceof KtWhenExpression) {
        for (var child = owner.getFirstChild(); child != null; child = child.getNextSibling())
          if (child instanceof PsiComment) members.add(child);
      }
      int base = lineAt.applyAsInt(brace.getTextOffset());
      if (owner instanceof KtBlockExpression
          && owner.getParent() instanceof KtNamedFunction function)
        base = lineAt.applyAsInt(function.getTextRange().getStartOffset());
      for (var child : members) {
        int line = lineAt.applyAsInt(child.getTextRange().getStartOffset());
        int end = lineAt.applyAsInt(child.getTextRange().getEndOffset() - 1);
        if (line != base) result.add(new Indent(line, base, end));
      }
    }
    result.sort(
        java.util.Comparator.comparingInt(Indent::line)
            .thenComparing(java.util.Comparator.comparingInt(Indent::end).reversed()));
    return result;
  }

  private static int indentation(String line) {
    int result = 0;
    while (result < line.length() && line.charAt(result) == ' ') result++;
    return result;
  }

  private static List<Integer> operatorBreaks(PsiElement file) {
    var source = file.getText();
    var result = new ArrayList<Integer>();
    for (var binary : PsiTreeUtil.findChildrenOfType(file, KtBinaryExpression.class)) {
      var left = binary.getLeft();
      if (left == null) continue;
      int end = left.getTextRange().getEndOffset();
      int operator = binary.getOperationReference().getTextOffset();
      if (source.substring(end, operator).contains("\n"))
        result.add((int) source.substring(0, operator).chars().filter(c -> c == '\n').count() + 1);
    }
    return result;
  }

  private static List<String> braceViolations(PsiElement file) {
    var source = file.getText();
    var result = new ArrayList<String>();
    java.util.function.BiConsumer<PsiElement, String> add =
        (node, message) ->
            result.add(
                (source.substring(0, node.getTextOffset()).chars().filter(c -> c == '\n').count()
                        + 1)
                    + ": "
                    + message);
    for (var branch : PsiTreeUtil.findChildrenOfType(file, KtWhenEntry.class))
      if (branch.getText().contains("\n") && !(branch.getExpression() instanceof KtBlockExpression))
        add.accept(branch, "multiline when branch requires braces");
    for (var conditional : PsiTreeUtil.findChildrenOfType(file, KtIfExpression.class))
      if (conditional.getText().contains("\n")
          && (!(conditional.getThen() instanceof KtBlockExpression)
              || (conditional.getElse() != null
                  && !(conditional.getElse() instanceof KtBlockExpression)
                  && !(conditional.getElse() instanceof KtIfExpression))))
        add.accept(conditional, "multiline if requires braces");
    for (var loop : PsiTreeUtil.findChildrenOfType(file, KtLoopExpression.class))
      if (!(loop.getBody() instanceof KtBlockExpression)) add.accept(loop, "loop requires braces");
    return result;
  }

  public static void main(String[] args) throws Exception {
    var disposable = Disposer.newDisposable();
    try {
      var environment =
          KotlinCoreEnvironment.createForProduction(
              disposable, new CompilerConfiguration(), EnvironmentConfigFiles.JVM_CONFIG_FILES);
      var factory = new KtPsiFactory(environment.getProject(), false);
      for (var pair :
          List.of(
              List.of("val x = -1", "val x = 1"),
              List.of("val x = 1", "var x = 1"),
              List.of("val x = \"before\"", "val x = \"after\""),
              List.of("val x = \"\\$name\"", "val x = \"$name\""))) {
        if (tree(factory.createFile(pair.get(0))).equals(tree(factory.createFile(pair.get(1)))))
          throw new AssertionError("Kotlin syntax comparison erased a semantic difference");
      }
      if (!tree(factory.createFile("fun f(a: Int,) = a"))
          .equals(tree(factory.createFile("fun f(a: Int) = a"))))
        throw new AssertionError("Optional trailing comma changed the syntax comparison");
      if (!operatorBreaks(factory.createFile("val x = true\n    && false")).equals(List.of(2))
          || !operatorBreaks(factory.createFile("val x = true &&\n    false")).isEmpty())
        throw new AssertionError("Kotlin operator wrapping check failed");
      for (boolean valid : List.of(true, false)) {
        var source =
            "fun f(): List<\n    Int> {\n" + (valid ? "    " : "") + "return emptyList()\n}\n";
        var lines = source.split("\n");
        boolean badIndent =
            indents(factory.createFile(source), source).stream()
                .anyMatch(
                    item -> indentation(lines[item.line()]) < indentation(lines[item.base()]) + 4);
        if (badIndent == valid)
          throw new AssertionError("Wrapped function return type changed body indentation");
      }
      for (var invalid :
          List.of(
              "val x = if (true)\n  1 else 0",
              "val x = when (1) {1 ->\n  2\nelse -> 3}",
              "fun f() { while (true) 1 }"))
        if (braceViolations(factory.createFile(invalid)).isEmpty())
          throw new AssertionError("Missing Kotlin brace diagnostic");
      for (var valid :
          List.of(
              "val x = if (true) 1 else 0",
              "val x = if (true) {\n  1\n} else {\n  0\n}",
              "fun f() { while (true) { 1 } }"))
        if (!braceViolations(factory.createFile(valid)).isEmpty())
          throw new AssertionError("Incorrect Kotlin brace diagnostic");
      if (args[0].equals("--format-blocks")) {
        for (int i = 1; i < args.length; i++) {
          var path = Path.of(args[i]);
          var source = Files.readString(path);
          var file = factory.createFile(source);
          if (!PsiTreeUtil.findChildrenOfType(file, PsiErrorElement.class).isEmpty())
            throw new AssertionError("Invalid Kotlin: " + path);
          var lines = source.split("\n", -1);
          for (var requirement : indents(file, source)) {
            int delta =
                indentation(lines[requirement.base()]) + 4 - indentation(lines[requirement.line()]);
            if (delta <= 0) continue;
            for (int n = requirement.line(); n <= requirement.end(); n++)
              if (!lines[n].isEmpty()) lines[n] = " ".repeat(delta) + lines[n];
          }
          var formatted = String.join("\n", lines);
          if (!tree(file).equals(tree(factory.createFile(formatted))))
            throw new AssertionError("Block formatting changed Kotlin syntax: " + path);
          Files.writeString(path, formatted);
          System.out.println(path + ": block indentation formatted");
        }
        return;
      }
      var failures = new ArrayList<String>();
      int checked = 0;
      for (String line : Files.readAllLines(Path.of(args[0]))) {
        var paths = line.split("\t");
        var filename =
            paths.length > 2 && paths[2].endsWith(".kts") ? "generated.kts" : "generated.kt";
        var readable = factory.createFile(filename, Files.readString(Path.of(paths[0])));
        var compact = factory.createFile(filename, Files.readString(Path.of(paths[1])));
        for (var file : List.of(readable, compact)) {
          for (var error : PsiTreeUtil.findChildrenOfType(file, PsiErrorElement.class))
            failures.add(paths[0] + ": parse error: " + error.getErrorDescription());
        }
        var before = tree(readable);
        var after = tree(compact);
        if (!before.equals(after)) {
          int at = 0;
          while (at < Math.min(before.length(), after.length())
              && before.charAt(at) == after.charAt(at)) at++;
          failures.add(
              paths[0]
                  + ": readable/compact Kotlin syntax trees differ at "
                  + at
                  + "\n"
                  + before.substring(Math.max(0, at - 50), Math.min(before.length(), at + 100))
                  + "\n"
                  + after.substring(Math.max(0, at - 50), Math.min(after.length(), at + 100)));
        }
        var imports = readable.getImportDirectives().stream().map(PsiElement::getText).toList();
        if (!imports.equals(imports.stream().sorted().toList())
            || readable.getImportDirectives().stream().anyMatch(item -> item.isAllUnder()))
          failures.add(paths[0] + ": imports must be sorted and explicit");
        var source = readable.getText();
        var lines = source.split("\n", -1);
        var label = paths.length > 2 ? paths[2] : paths[0];
        for (var requirement : indents(readable, source)) {
          int expected = indentation(lines[requirement.base()]) + 4;
          if (indentation(lines[requirement.line()]) != expected)
            failures.add(
                label
                    + ":"
                    + (requirement.line() + 1)
                    + ": block/argument indentation needs "
                    + expected);
        }
        for (var violation : braceViolations(readable)) failures.add(label + ":" + violation);
        for (int operatorLine : operatorBreaks(readable))
          failures.add(label + ":" + operatorLine + ": break after the binary operator");
        for (int n = 0; n < lines.length; n++) {
          var text = lines[n];
          if (text.endsWith(" ") || text.endsWith("\t") || text.startsWith("\t"))
            failures.add(label + ":" + (n + 1) + ": tabs or trailing whitespace");
          if (text.codePointCount(0, text.length()) > 100
              && !text.startsWith("package ")
              && !text.startsWith("import "))
            failures.add(label + ":" + (n + 1) + ": exceeds 100 columns");
        }
        checked++;
      }
      for (var failure : failures) System.err.println(failure);
      if (!failures.isEmpty()) throw new AssertionError(failures.size() + " Kotlin checks failed");
      System.out.println(
          checked
              + " Kotlin artifacts pass parsing, syntax-tree parity, block/argument indentation,"
              + " columns, imports, operators and braces");
    } finally {
      Disposer.dispose(disposable);
    }
  }
}
