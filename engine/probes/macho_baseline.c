// Link an ordinary arm64 iOS executable for load-command inspection.
// The linker may add an ad-hoc signature; no identity/provisioning is requested.
// Never run this device executable on the CI host.
int main(void) { return 0; }
