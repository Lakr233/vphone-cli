// Producers for the helper lookup order (rule 4): same file, module dir, repo, icli.
func sameFile() -> [String: Any] { return ["file": 1] }
func viaSameFile() -> [String: Any] { return sameFile() }
func viaModule() -> [String: Any] { return moduleOnly() }
func viaRepo() -> [String: Any] { return repoOnly() }
func viaIcli() -> [String: Any] { return icliOnly() }
func viaShadow() -> [String: Any] { return shadowed() }
func viaTwins() -> [String: Any] { return twins() }
func viaMissing() -> [String: Any] { return nowhere() }
