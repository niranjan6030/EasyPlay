import Foundation

// Run with: swift run easyplay-tests
try WineEnvironmentTests.run()
try ExecutableFinderTests.run()
try LogClassifierTests.run()
try RecipeLibraryTests.run()

exit(Harness.summarise())
