fx_version 'cerulean'
game 'gta5'

author 'nzkfc'
description 'nzkfc_drone - Drone companion script for ox_inventory servers'
version '1.0.1'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/drone_movement.lua',
    'client/drone_control.lua',
    'client/drone_targeting.lua',
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_inventory',
    'ox_target',
    'oxmysql',
}

-- Special thanks to:
-- breadlord. for the concept idea <3
-- monesuper for the native audio suggestion and audio ref info <3
