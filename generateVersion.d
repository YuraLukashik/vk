import std.process, std.stdio, std.string, std.algorithm,
       std.file, std.regex, std.conv;

void main() {
  const versionNum = "0.7.2";
  const releaseFlag = false;
  immutable string
    lastCommitHash = matchFirst(executeShell("git log -1").output, regex(r"(?:^commit\s+)([0-9a-f]{40})"))[1][0..7],
    currentBranch = matchFirst(executeShell("git status").output, regex(r"(?:^On branch\s+)(.+)"))[1];

  auto verTemplate = "
module vkversion;

const string
  currentVersion = \"master\";

";

  auto fileName = "source/vkversion.d";
  string[] text;

  if(!exists(fileName)) text = verTemplate.split("\n");
  else text = readText(fileName).split("\n");

  auto reg = regex("(^\\s*currentVersion\\s*=\\s*\")(.+)(\"\\s*;)");
  foreach (ref line; text) {
    auto match = matchFirst(line, reg);
    if (match.length == 4) {
      auto versionString = releaseFlag ? versionNum : versionNum ~ "-" ~ currentBranch ~ "-" ~ lastCommitHash;
      writeln("version string: " ~ versionString);
      line = match[1] ~ versionString ~ match[3];
      break;
    }
  }
  auto f = File(fileName, "w");
  f.write(text.join("\n"));
  f.close;
}
