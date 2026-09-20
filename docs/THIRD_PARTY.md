# Third-party libraries

Luma bundles dynamically linked copies of MPFR 4.2.2 and GMP 6.3.0 from Homebrew.

- MPFR: https://www.mpfr.org/mpfr-4.2.2/ , GNU Lesser General Public License, version 3 or later.
- GMP: https://gmplib.org/ , dual LGPLv3+ or GPLv2+; used under LGPLv3+ here.

License texts are bundled in Contents/Resources/Licenses. Corresponding source is available at https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.xz and https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz, and is attached to the GitHub release. These are unmodified Homebrew libraries. They can be replaced in Contents/Frameworks with ABI-compatible builds and the local app can be ad-hoc signed again using codesign. Build scripts and app source are supplied with this project. The packaging script supports Developer ID signing and notarization when a saved credential profile is supplied. See each release's notes for its signing and notarization status.
