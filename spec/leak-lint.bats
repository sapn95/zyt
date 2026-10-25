#!/usr/bin/env bats
#
# The address lint, and above all what it does when it cannot look. A check that
# passes because it could not run is worse than no check, because the green tick
# is the same one a clean tree gets.

setup() {
  TMP="$(mktemp -d)"
  STUB="${TMP}/bin"
  mkdir -p "${TMP}/repo/scripts" "${STUB}"
  # The script searches the repository its own directory sits in, so the copy
  # brings a repository of its own. A test that wrote a real address into this
  # checkout to see the lint catch it would be a test that leaks one.
  SCRIPT="${TMP}/repo/scripts/leak-lint.sh"
  cp "${BATS_TEST_DIRNAME}/../scripts/leak-lint.sh" "${SCRIPT}"
  chmod +x "${SCRIPT}"

  # The address the lint is meant to object to cannot be written down here in one
  # piece: the lint reads this file too and would object to it, which is the
  # check working. Octets joined at run time, a public resolver everybody knows.
  LEAKED="$(printf '%s.%s.%s.%s' 8 8 8 8)"

  # A private address. Nothing here invents one, so the whole class is refused,
  # and this is the class an employer's network hands out: a proxy or a host
  # copied off a real machine is made of these. Joined at run time for the same
  # reason as the one above.
  INTERNAL="$(printf '10.%s.%s.%s' 245 0 225)"

  cd "${TMP}/repo" || return 1
  git init -q -b main .
  printf 'the host answers on 192.0.2.1 and the other one on 198.51.100.7\n' > allowed.md
  git add allowed.md
}

teardown() {
  cd "${BATS_TEST_DIRNAME}" || true
  rm -rf "${TMP}"
}

@test "passes when every address is a documentation one" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"every address written down here is a documentation one"* ]]
}

@test "objects to a private address, which is nothing this repository invents" {
  printf 'the proxy is %s\n' "${INTERNAL}" > proxy.md
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"proxy.md:1: ${INTERNAL} is not a documentation address"* ]]
  [[ "${output}" == *"not safe by being private"* ]]
}

@test "names the file, the line and the address it objects to" {
  printf 'first line\nthe resolver is %s\n' "${LEAKED}" > leaky.md
  git add leaky.md
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"leaky.md:2: ${LEAKED} is not a documentation address"* ]]
  [[ "${output}" == *"192.0.2.x"* ]]
}

@test "catches an untracked file, before anybody has added it" {
  printf 'the resolver is %s\n' "${LEAKED}" > leaky.md
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"${LEAKED} is not a documentation address"* ]]
}

@test "reads what is staged when the working copy is gone" {
  printf 'the resolver is %s\n' "${LEAKED}" > staged.md
  git add staged.md
  rm staged.md
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"staged.md:1: ${LEAKED} is not a documentation address"* ]]
}

@test "looks inside a file that has a NUL byte in it" {
  # Left to itself grep calls this one a binary file, says it matches and exits
  # 0 without printing the match, which is an address in the tree and not in the
  # output.
  printf 'a\000 the resolver is %s\n' "${LEAKED}" > binary.md
  git add binary.md
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"${LEAKED} is not a documentation address"* ]]
}

@test "a file name with a tab and a colon in it cannot hide an address" {
  # The name is put in front of the match, so a name that looks like the start of
  # a record is a name that could carry the rest of one. This one ends in an
  # allowed address: read as the match, the disallowed address behind it would
  # look like a documentation address with something appended.
  odd="$(printf 'odd\tname:192.0.2.1')"
  printf 'the resolver is %s\n' "${LEAKED}" > "${odd}"
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"${LEAKED} is not a documentation address"* ]]
}

@test "leaves the files git is told to ignore alone" {
  printf 'notes.md\n' > .gitignore
  printf 'the resolver is %s\n' "${LEAKED}" > notes.md
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "fails when git cannot say what the files are" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUB}/git"
  chmod +x "${STUB}/git"
  PATH="${STUB}:${PATH}" run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"every address written down here"* ]]
}

@test "fails when a file cannot be searched" {
  # Exit 2 is what grep says when it could not read what it was given. Exit 1,
  # the file with no address in it, is the only failure that means nothing.
  printf '#!/usr/bin/env bash\nexit 2\n' > "${STUB}/grep"
  chmod +x "${STUB}/grep"
  PATH="${STUB}:${PATH}" run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not be searched"* ]]
}
