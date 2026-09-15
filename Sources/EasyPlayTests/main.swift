import Foundation

// Run with: swift run easyplay-tests
try WineEnvironmentTests.run()
try ExecutableFinderTests.run()
try LogClassifierTests.run()
try RecipeLibraryTests.run()
try GameStoreTests.run()
try GraphicsProbeTests.run()
try WindowsExecutableTests.run()
try AdvisorTests.run()
try SteamTests.run()
try SteamCMDTests.run()

exit(Harness.summarise())
