package.loaded.mq = {
    configDir = 'F:\\Config',
    TLO = {},
}

local Paths = require('sidekick-next.utils.paths')

assert(Paths.normalize('F:\\Config/SideKick-Next\\data')
    == 'F:/Config/SideKick-Next/data')
assert(Paths.getRootDir() == 'F:/Config/SideKick-Next')
assert(Paths.getLegacyRootDir() == 'F:/Config/SideKick')

print('paths_normalization_test: 3 checks, 0 failures')
