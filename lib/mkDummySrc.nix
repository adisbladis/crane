{ cleanCargoToml
, findCargoFiles
, lib
, runCommandLocal
, writeText
, writeTOML
}:

{ src
, cargoLock ? null
, ...
}:
let
  inherit (builtins)
    dirOf
    concatStringsSep
    hasAttr
    pathExists;

  inherit (lib)
    optionalString
    removePrefix;

  inherit (lib.strings) concatStrings;

  # A quick explanation of what is happening here and why it is done in the way
  # that it is:
  #
  # We want to build a dummy version of the project source. The only things that
  # we want to keep are:
  # 1. the Cargo.lock file
  # 2. any .cargo/config.toml files (unaltered)
  # 3. any Cargo.toml files stripped down only the attributes that would affect
  # caching dependencies
  #
  # Any other sources are completely ignored, and so, we want to avoid any of those ignored sources
  # leading to invalidating our caches. Normally if a build script references any data from another
  # derivation, Nix will consider that entire derivation as an input and any changes to it or its
  # inputs would invalidate the consumer. But we can try to get a bit clever:
  #
  # If we "break up" the input source into smaller parts (i.e. only the parts we care about) we can
  # avoid the "false dependency" invalidation. One trick to accomplishing this is by "laundering"
  # the data at evaluation time: we have Nix read the data out, do some TOML transformations, write
  # it to a fresh file, and then have other derivations consume _that result_. The only thing we
  # have to be careful about is stripping away any "context" Nix may be tracking for the input as we
  # work with it: specifically if the `src` input provided by the caller happens to point to a
  # derivation output (e.g. including using an entire flake source like `{ src = self; }`). Nix
  # carries this "context" to any other strings operations which touch the derivation output (e.g.
  # appending path components). In most cases this is the right thing do to since a derivation which
  # consumes any part of another derivation _probably_ needs to be rebuilt if the latter changes,
  # but here we will explicitly strip the context out since we want to break this dependency.
  # This way, adding a comment or editing an ignored field won't lead to rebuilding everything from
  # scratch!
  #
  # The other trick to accomplishing a similar feat (but without rewriting the files at evaluation
  # time) is to use Nix's source filtering. We give Nix some source path and a function, and Nix
  # will create a brand new entry in the store after while asking the function whether each and
  # every file or directory under said path should be kept or not. The result is that only changes
  # to the kept files would result in rebuilding the consumers.
  #
  # Thus to avoid accidental rebuilds, we need to explicitly filter the source to only contain the
  # files we care about (namely, the .cargo/config.toml files and the Cargo.lock file, we're already
  # cleaning up the Cargo.toml files during evaluation). There is one extra hurdle we have to clear:
  # Nix's source filtering operates in a top-down lazy manner. For every directory it encounters it
  # will ask "should this be kept or not?" If the answer is "no" it skips the directory entirely,
  # which is reasonable. The problem is the function won't know what files that directory may or may
  # not contain unless it indicates the directory should be kept. If that happens but the function
  # rejects all other files under the directory, Nix just keeps the (now empty) directory and moves
  # on. This isn't a huge problem, except that adding a new directory _anywhere_ in the flake root
  # would also invalidate everything again.
  #
  # Finally we pull one last trick up our sleeve: we do the filtering in two passes! First, at
  # evaluation time, we walk the input path and look for any interesting files (i.e.
  # .cargo/config.toml and Cargo.lock files) and remember at what paths they appear relative to the
  # input source. Then we run the source filtering and use that information to guide which files are
  # kept. Namely, if the path being filtered is a regular file, we check if its path (relative to
  # the source root) matches one of our interesting files. If the path being filtered is a
  # directory, we check if it happens to be an ancestor for an interesting file (i.e. is a prefix of
  # an interesting file). That way we are left with the smallest possible source needed for our
  # dummy derivation, and we bring any cache invalidation to a minimum. Whew!
  mkBasePath = p: (toString p) + "/";
  uncleanSrcBasePath = mkBasePath src;

  uncleanFiles = findCargoFiles src;

  cargoTomlsBase = uncleanSrcBasePath;
  inherit (uncleanFiles) cargoTomls;

  cleanSrc =
    let
      adjustPaths = builtins.map (p: removePrefix uncleanSrcBasePath (toString p));
      allUncleanFiles = map
        (p: removePrefix uncleanSrcBasePath (toString p))
        # Allow the default `Cargo.lock` location to be picked up here
        # (if it exists) so it automattically appears in the cleaned source
        (uncleanFiles.cargoConfigs ++ [ "Cargo.lock" ]);
    in
    lib.cleanSourceWith {
      inherit src;
      name = "cleaned-mkDummySrc";
      filter = path: type:
        let
          strippedPath = removePrefix uncleanSrcBasePath path;
          filter = x:
            if type == "directory" then
              lib.hasPrefix strippedPath x
            else
              x == strippedPath;
        in
        lib.any filter allUncleanFiles;
    };

  dummyrs = writeText "dummy.rs" ''
    #![allow(dead_code)]
    pub fn main() {}
  '';

  cpDummy = prefix: path: ''
    mkdir -p ${prefix}/${dirOf path}
    cp -f ${dummyrs} ${prefix}/${path}
  '';

  copyAndStubCargoTomls = concatStrings (map
    (p:
      let
        # Safety: all the paths here are fully processed/consumed at evaluation time, so it is is
        # safe to throw away any context (to the Nix store) the original path may have carried.
        # Given that we call `cleanSourceWith` earlier, we know that the input `src` must be valid
        # (or else we would have other errors to deal with)
        cargoTomlDest = builtins.unsafeDiscardStringContext (removePrefix cargoTomlsBase (toString p));
        parentDir = "$out/${dirOf cargoTomlDest}";

        trimmedCargoToml = cleanCargoToml {
          cargoToml = p;
        };

        safeStubLib =
          if hasAttr "lib" trimmedCargoToml
          then cpDummy parentDir (trimmedCargoToml.lib.path or "src/lib.rs")
          else "";

        safeStubList = attr: defaultPath:
          let
            targetList = trimmedCargoToml.${attr} or [ ];
            paths = map (t: t.path or "${defaultPath}/${t.name}.rs") targetList;
            commands = map (cpDummy parentDir) paths;
          in
          concatStringsSep "\n" commands;
      in
      ''
        mkdir -p ${parentDir}
        cp ${writeTOML "Cargo.toml" trimmedCargoToml} $out/${cargoTomlDest}
      '' + optionalString (trimmedCargoToml ? package) ''
        # To build build-dependencies
        ${cpDummy parentDir "build.rs"}
        # To build regular and dev dependencies (cargo build + cargo test)
        ${cpDummy parentDir "src/lib.rs"}

        # Stub all other targets in case they have particular feature combinations
        ${safeStubLib}
        ${safeStubList "bench" "benches"}
        ${safeStubList "bin" "src/bin"}
        ${safeStubList "example" "examples"}
        ${safeStubList "test" "tests"}
      ''
    )
    cargoTomls
  );

  # Since we allow the caller to provide a path to *some* Cargo.lock file
  # we include it in our dummy build only if it was explicitly specified
  # and the path exists.
  copyCargoLock =
    if cargoLock == null
    then ""
    else if pathExists cargoLock
    then "cp ${cargoLock} $out/Cargo.lock"
    else throw "`cargoLock` was specified but the path it points to does not exist: ${cargoLock}";
in
runCommandLocal "dummy-src" { } ''
  mkdir -p $out
  cp --recursive --no-preserve=mode,ownership ${cleanSrc}/. -t $out
  ${copyCargoLock}
  ${copyAndStubCargoTomls}
''
