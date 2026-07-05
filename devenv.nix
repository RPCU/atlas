{
  pkgs,
  lib,
  ...
}:
let
  packageList = with pkgs; [
    jq
    yq
    go-task
    fluxcd
    kustomize
    kubernetes-helm
  ];

  # Extract package names and generate formatted list
  packageNames = map (pkg: pkg.pname or pkg.name) packageList;
  toolsDisplay = lib.concatStringsSep "\n" (map (name: "  ${name}") packageNames);
in
{
  # https://devenv.sh/basics/
  env.GREET = "Welcome to the Atlas environment!";

  packages = packageList;
  scripts = {
    # https://devenv.sh/scripts/
    hello.exec = ''
      echo $GREET
    '';
  };

  enterShell = ''
        hello
        echo ""
        echo "Available tools:"
        cat << 'EOF'
    ${toolsDisplay}
    EOF
        echo ""
        echo "Custom scripts:"
        echo "  hello            - Prints greeting"
  '';

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    hello | grep "Welcome"
  '';
}
