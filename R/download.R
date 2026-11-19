# Pre-built libraries. A client can offer private libraries its authors built
# for some platforms, listed in the
# file `jlbind/binaries` of the installed package (`inst/jlbind/binaries` in
# its sources): a DCF file with a record per platform,
#
#   Version: 0.1.0        (of the package it was built from)
#   OS: Linux             (Sys.info()[["sysname"]])
#   Arch: x86_64          (R.version$arch)
#   URL: https://...      (a .tar.gz of the directory build_library() wrote)
#   SHA256: <64 hex digits>
#
# install_library(method = "download") downloads the one for this platform,
# checks it against the SHA-256 hash the package ships, and installs it where
# install_library() would build it: as the client's private library. The file
# is not in the binding package, whose files are
# hashed into the library's record, so that the hashes can be added after the
# libraries are built.

# The version of the interface between jlbind and a compiled library: the C
# routines that call the library (src/call.c, src/state.c) and the JLBind
# code compiled into it. A pre-built library records the version it was built
# for, and is only installed and kept by a jlbind with the same one, while
# other jlbind versions build their libraries themselves. Bump it whenever a
# library built by an earlier jlbind would not work with this one.
.binary_abi <- 1L

# The platform pre-built libraries are chosen by, as in `jlbind/binaries`.
.platform <- function() {
  c(OS = Sys.info()[["sysname"]], Arch = R.version$arch)
}

.platform_name <- function() {
  p <- .platform()
  paste0(p[["OS"]], " (", p[["Arch"]], ")")
}

# The pre-built libraries the installed package `pkg` offers, as listed in
# `file`: a data frame with Version, OS, Arch, URL and SHA256, with no rows if
# it offers none.
.binaries <- function(
  pkg,
  file = system.file("jlbind", "binaries", package = pkg)
) {
  fields <- c("Version", "OS", "Arch", "URL", "SHA256")
  if (!nzchar(file)) {
    return(as.data.frame(
      matrix(character(), 0L, length(fields), dimnames = list(NULL, fields))
    ))
  }
  out <- as.data.frame(read.dcf(file, fields = fields))
  bad <- rowSums(is.na(out)) > 0L | !grepl("^[0-9a-fA-F]{64}$", out$SHA256)
  if (any(bad)) {
    stop(
      "The list of pre-built libraries of ",
      pkg,
      " (",
      file,
      ") is malformed: each entry needs a Version, OS, Arch, URL and a ",
      "SHA256 of 64 hexadecimal digits.",
      call. = FALSE
    )
  }
  out$SHA256 <- tolower(out$SHA256)
  out
}

# The pre-built library `pkg` offers for this platform (a one-row data frame),
# or NULL: the one for version `version` if it lists one, else the first.
.binary_for <- function(pkg, version = NULL, platform = .platform()) {
  b <- .binaries(pkg)
  b <- b[
    b$OS == platform[["OS"]] & b$Arch == platform[["Arch"]],
    ,
    drop = FALSE
  ]
  if (!is.null(version) && any(b$Version == version)) {
    b <- b[b$Version == version, , drop = FALSE]
  }
  if (nrow(b)) b[1L, , drop = FALSE]
}

# Whether the library recorded as `build` (.read_build()) was installed by
# install_library(method = "download").
.is_downloaded <- function(build) {
  d <- build$Download
  !is.null(d) && !is.na(d) && nzchar(d)
}

# Which of `packages` have a pre-built private library.
.downloaded_packages <- function(packages) {
  dirs <- .private_dir(packages)
  packages[vapply(
    dirs,
    function(dir) {
      file.exists(file.path(dir, .library_file())) &&
        .is_downloaded(.read_build(dir))
    },
    TRUE
  )]
}

# The SHA-256 hash of `file`, in lower-case hex.
.sha256 <- function(file) {
  # tools::sha256sum() is new in R 4.5.0.
  sha256sum <- get0("sha256sum", envir = asNamespace("tools"), inherits = FALSE)
  if (!is.null(sha256sum)) {
    return(tolower(unname(sha256sum(file))))
  }
  if (requireNamespace("openssl", quietly = TRUE)) {
    con <- file(file, "rb")
    on.exit(close(con))
    return(as.character(openssl::sha256(con)))
  }
  stop(
    "Checking a download needs R >= 4.5.0 or the openssl package: ",
    "install.packages(\"openssl\").",
    call. = FALSE
  )
}

# install_library(method = "download"): installs the pre-built libraries of
# `packages` (by default, every client that offers one for this platform).
.install_download <- function(
  packages = NULL,
  ask = interactive(),
  force = FALSE
) {
  clients <- jlbind_clients()
  if (!is.null(packages)) {
    missing <- setdiff(packages, clients$package)
    if (length(missing)) {
      stop(
        "Not an installed package that uses jlbind: ",
        paste(missing, collapse = ", "),
        ".",
        call. = FALSE
      )
    }
    clients <- clients[match(unique(packages), clients$package), , drop = FALSE]
  }
  if (nrow(clients) == 0L) {
    message(
      "No installed package uses jlbind, so there is nothing to download."
    )
    return(invisible(NULL))
  }
  offers <- unname(Map(.binary_for, clients$package, clients$version))
  # Libraries listed for another version, as in the sources between releases,
  # are not worth downloading.
  other <- vapply(
    seq_along(offers),
    function(i) {
      !is.null(offers[[i]]) && offers[[i]]$Version != clients$version[[i]]
    },
    TRUE
  )
  if (any(other)) {
    msg <- paste0(
      vapply(
        which(other),
        function(i) {
          paste0(
            clients$package[[i]],
            " ",
            clients$version[[i]],
            " lists a pre-built library for version ",
            offers[[i]]$Version,
            " only"
          )
        },
        ""
      ),
      collapse = "; "
    )
    msg <- paste0(
      msg,
      ". Install a released version of ",
      if (sum(other) > 1L) "these packages" else "it",
      ", or build the library with jlbind::install_library()."
    )
    if (!is.null(packages)) {
      stop(msg, call. = FALSE)
    }
    message(msg)
    offers[other] <- list(NULL)
  }
  none <- vapply(offers, is.null, TRUE) & !other
  if (any(none)) {
    msg <- paste0(
      paste(clients$package[none], collapse = ", "),
      if (sum(none) > 1L) " offer" else " offers",
      " no pre-built library for ",
      .platform_name(),
      "; build ",
      if (sum(none) > 1L) "them" else "it",
      " with jlbind::install_library() instead, which needs Julia >= 1.13."
    )
    if (!is.null(packages)) {
      stop(msg, call. = FALSE)
    }
    message(msg)
  }
  none <- none | other
  clients <- clients[!none, , drop = FALSE]
  offers <- offers[!none]
  if (nrow(clients) == 0L) {
    return(invisible(NULL))
  }
  dirs <- .private_dir(clients$package)
  current <- vapply(
    seq_along(dirs),
    function(i) {
      build <- .read_build(dirs[[i]])
      file.exists(file.path(dirs[[i]], .library_file())) &&
        identical(unname(build$SHA256), offers[[i]]$SHA256)
    },
    TRUE
  )
  paths <- file.path(dirs, .library_file())
  todo <- which(force | !current)
  if (!length(todo)) {
    message(
      "The pre-built ",
      if (length(paths) > 1L) "libraries are" else "library is",
      " up to date (",
      paste(paths, collapse = ", "),
      "); use `force = TRUE` to download ",
      if (length(paths) > 1L) "them" else "it",
      " again."
    )
    .bind_requested()
    return(invisible(paths[[1L]]))
  }

  if (isTRUE(ask)) {
    choice <- utils::menu(
      c("Yes", "No"),
      title = paste0(
        "Download the pre-built Julia ",
        if (length(todo) > 1L) "libraries" else "library",
        " of ",
        paste(clients$package[todo], collapse = ", "),
        " (from ",
        paste(vapply(offers[todo], `[[`, "", "URL"), collapse = ", "),
        ") into ",
        tools::R_user_dir("jlbind", "data"),
        "?"
      )
    )
    if (choice != 1L) {
      message("Cancelled.")
      return(invisible(NULL))
    }
  }

  for (i in todo) {
    .install_binary(
      clients$package[[i]],
      clients$version[[i]],
      offers[[i]],
      dirs[[i]],
      salt = .salt(clients$package[[i]])
    )
  }
  noun <- if (length(todo) > 1L) "libraries" else "library"
  message(
    "Installed the pre-built Julia ",
    noun,
    " of ",
    paste(clients$package[todo], collapse = ", "),
    ".",
    if (length(.loaded_libraries())) {
      paste0(
        " Restart R to use ",
        if (length(todo) > 1L) "them" else "it",
        " in place of the libraries loaded in this session."
      )
    }
  )
  .bind_requested()
  invisible(paths[[1L]])
}

# Downloads the pre-built library `offer` (a row of .binaries()) of version
# `version` of `pkg`, checks it, and installs it into `dir`. It must be a
# private library with salt `salt`.
.install_binary <- function(pkg, version, offer, dir, salt = NULL) {
  root <- dirname(dir)
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  # Named like a build directory, so that .prune_builds() removes it if R is
  # killed before it is moved into place.
  work <- tempfile("build-", tmpdir = root)
  dir.create(work)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  archive <- file.path(work, "library.tar.gz")

  # The default timeout of 60 seconds is short for a library of tens of MB.
  old <- options(timeout = max(600, getOption("timeout")))
  on.exit(options(old), add = TRUE)
  status <- tryCatch(
    utils::download.file(offer$URL, archive, mode = "wb", quiet = TRUE),
    error = identity,
    warning = identity
  )
  if (inherits(status, "condition") || !identical(status, 0L)) {
    stop(
      "Could not download the pre-built library of ",
      pkg,
      " from ",
      offer$URL,
      if (inherits(status, "condition")) paste0(": ", conditionMessage(status)),
      call. = FALSE
    )
  }

  # Checked before the archive is even opened.
  hash <- .sha256(archive)
  if (!identical(hash, offer$SHA256)) {
    stop(
      "The pre-built library of ",
      pkg,
      " downloaded from ",
      offer$URL,
      " is not the one ",
      pkg,
      " lists (its SHA-256 hash is ",
      hash,
      ", not ",
      offer$SHA256,
      "), so it was not installed. The download may have been corrupted or ",
      "tampered with; try again, or build the library with ",
      "jlbind::install_library().",
      call. = FALSE
    )
  }

  out <- file.path(work, "library")
  if (!identical(utils::untar(archive, exdir = out), 0L)) {
    stop(
      "Could not unpack the pre-built library of ",
      pkg,
      ".",
      call. = FALSE
    )
  }
  problem <- .binary_problem(out, pkg, version, salt)
  if (!is.null(problem)) {
    stop(
      "The pre-built library of ",
      pkg,
      " from ",
      offer$URL,
      " can't be used: ",
      problem,
      ". Build it with jlbind::install_library() instead.",
      call. = FALSE
    )
  }
  # Recorded with how it was built, so that later builds leave it alone, it is
  # not downloaded again, and the hints say how to update it.
  build <- as.data.frame(read.dcf(file.path(out, "build")))
  build$Download <- offer$URL
  build$SHA256 <- hash
  write.dcf(build, file.path(out, "build"))
  .replace_dir(out, dir)
}

# Why the unpacked pre-built library in `dir` can't serve version `version`
# of `pkg`, or NULL. It needs a private runtime, with salt `salt` if given.
.binary_problem <- function(dir, pkg, version, salt = NULL) {
  build <- .read_build(dir)
  clients <- .read_clients(dir)
  if (
    !file.exists(file.path(dir, .library_file())) ||
      is.null(build) ||
      is.null(clients)
  ) {
    return(paste0("the archive holds no ", .library_file(), " built by jlbind"))
  }
  row <- clients[clients$Package == pkg, , drop = FALSE]
  if (!nrow(row)) {
    return(paste0("it was built without ", pkg))
  }
  if (!identical(row$Version[[1L]], version)) {
    return(paste0(
      "it was built for ",
      pkg,
      " ",
      row$Version[[1L]],
      ", not the installed version ",
      version
    ))
  }
  if (!identical(unname(build$ABI), as.character(.binary_abi))) {
    return(paste0(
      "it was built for ",
      if (is.na(build$ABI)) {
        "an older version"
      } else {
        paste0("version ", build$ABI)
      },
      " of jlbind's interface to libraries, not ",
      .binary_abi,
      ", the version of this jlbind"
    ))
  }
  if (!identical(unname(build$Bundle), "TRUE")) {
    return("it has no Julia runtime of its own (built without `bundle`)")
  }
  private <- unname(.na_empty(build$Private))
  if (!nzchar(private)) {
    return(
      "it has no private Julia runtime (build it with `private = TRUE`)"
    )
  }
  if (!is.null(salt) && !identical(private, salt)) {
    return(paste0(
      "its private Julia runtime has the salt ",
      private,
      ", not ",
      salt
    ))
  }
  if (!is.na(build$CpuTarget) && grepl("native", build$CpuTarget)) {
    return("it was built for the CPU of the computer that built it")
  }
  NULL
}
