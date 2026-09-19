# Deploys the app to the given environment.
deploy() {
  build
  scp out.tar.gz "$1":/srv
}

build() {
  echo building
}

# standalone comment, not attached to anything
