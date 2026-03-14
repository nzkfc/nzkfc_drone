fx_version 'cerulean'
game 'gta5'

author 'nzkfc'
description 'nzkfc_drone - Drone companion script QBX compatible & ESX (Running ox_inventory)'
version '1.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/framework.lua',
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
    'ox_lib',
    'ox_inventory',
    'ox_target',
    'oxmysql',
}

optional_dependencies {
    'es_extended',
    'qbx_core',
}

-- Special thanks to:
-- breadlord. for the concept idea <3
-- monesuper for the native audio suggestion and audio ref info <3
