import Foundation

// Run with: swift run easyplay-tests
try WineEnvironmentTests.run()
try ExecutableFinderTests.run()
try ImportPathTests.run()
try DropAcceptanceTests.run()
try LogClassifierTests.run()
try RecipeLibraryTests.run()
try GameStoreTests.run()
try GraphicsProbeTests.run()
try WindowsExecutableTests.run()
try AdvisorTests.run()
try SteamTests.run()
try SteamCMDTests.run()
try SteamSignInSecurityTests.run()
try RegistryPatchTests.run()

exit(Harness.summarise())
