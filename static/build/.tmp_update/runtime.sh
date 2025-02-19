#!/bin/sh
sysdir=/mnt/SDCARD/.tmp_update
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$sysdir/lib:$sysdir/lib/parasyte"
export PATH="$sysdir/bin:$PATH"

main() {
    init_system
    update_time
    clear_logs

    # Start the battery monitor
    batmon &

    # Reapply theme
    system_theme="$(/customer/app/jsonval theme)"
    active_theme="$(cat ./config/active_theme)"

    if [ "$system_theme" == "./" ] || [ "$system_theme" != "$active_theme" ] || [ ! -d "$system_theme" ]; then
        themeSwitcher --reapply_icons
    fi
    
    if [ `cat /sys/devices/gpiochip0/gpio/gpio59/value` -eq 1 ]; then
        cd $sysdir
        chargingState
    fi

    # Make sure MainUI doesn't show charging animation
    touch /tmp/no_charging_ui

    cd $sysdir
    bootScreen "Boot"

    # Start the key monitor
    keymon &

    # Init
    rm /tmp/.offOrder
    HOME=/mnt/SDCARD/RetroArch/

    detectKey 1
    menu_pressed=$?

    if [ $menu_pressed -eq 0 ]; then
        rm -f "./cmd_to_run.sh" 2> /dev/null
    fi

    # Auto launch
    if [ ! -f $sysdir/config/.noAutoStart ]; then
        state_change
        check_game
    fi

    startup_app=`cat $sysdir/config/startup/app`

    if [ $startup_app -eq 1 ]; then
        touch $sysdir/.runGameSwitcher
    elif [ $startup_app -eq 2 ]; then
        cd /mnt/SDCARD/RetroArch/
        LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so ./retroarch -v
    fi

    state_change
    check_switcher

    set_startup_tab

    # Main runtime loop
    while true; do
        state_change
        check_main_ui
        state_change
        check_game_menu
        state_change
        check_game
        state_change  
        check_switcher
        
        # Free memory
        $sysdir/bin/freemma
    done
}

state_change() {
    touch /tmp/state_changed
    sync
}

clear_logs() {
    mkdir -p $sysdir/logs
    
    cd $sysdir
    rm -f \
        ./logs/MainUI.log \
        ./logs/gameSwitcher.log \
        ./logs/game_list_options.log
}

check_main_ui() {
    if [ ! -f $sysdir/cmd_to_run.sh ] ; then
        launch_main_ui
        check_off_order "End"
    fi
}

launch_main_ui() {
    cd $sysdir
    mainUiBatPerc

    check_hide_recents
    check_hide_expert

    # MainUI launch
    cd /mnt/SDCARD/miyoo/app
    LD_PRELOAD="/mnt/SDCARD/miyoo/lib/libpadsp.so" ./MainUI 2>&1 > /dev/null
    
    mv -f /tmp/cmd_to_run.sh $sysdir/cmd_to_run.sh

    echo "mainui" > /tmp/prev_state
}

check_game_menu() {
    if [ ! -f /tmp/launch_alt ]; then
        return
    fi
    
    rm -f /tmp/launch_alt

    if [ ! -f $sysdir/cmd_to_run.sh ]; then
        return
    fi
    
    launch_game_menu
}

launch_game_menu() {
    cd $sysdir
    echo -e "\n\n:: GLO\n\n"
    sync

    $sysdir/script/game_list_options.sh | tee -a ./logs/game_list_options.log

    if [ $? -ne 0 ]; then
        echo -e "\n\n< Back to MainUI\n\n"
        rm -f $sysdir/cmd_to_run.sh 2> /dev/null
        check_off_order "End"
    fi
}

check_game() {
    # Game launch
    if  [ -f $sysdir/cmd_to_run.sh ] ; then
        launch_game
    fi
}

check_is_game() {
    echo "$1" | grep -q "retroarch" || echo "$1" | grep -q "/../../Roms/"
}

launch_game() {
    cmd=`cat $sysdir/cmd_to_run.sh`

    is_game=0
    rompath=""
    romext=""
    romcfgpath=""
    retroarch_core=""

    # TIMER BEGIN
    if check_is_game "$cmd"; then
        rompath=$(echo "$cmd" | awk '{ st = index($0,"\" \""); print substr($0,st+3,length($0)-st-3)}')

        if echo "$rompath" | grep -q ":"; then
            rompath=$(echo "$rompath" | awk '{split($0,a,":"); print a[2]}')
        fi

        romext=`echo "$(basename "$rompath")" | awk -F. '{print tolower($NF)}'`
        romcfgpath="$(dirname "$rompath")/.game_config/$(basename "$rompath" ".$romext").cfg"

        if [ "$romext" != "miyoocmd" ]; then
            echo "rompath: $rompath (ext: $romext)"
            echo "romcfgpath: $romcfgpath"
            is_game=1
        fi
    fi

    if [ $is_game -eq 1 ]; then
        if [ -f "$romcfgpath" ]; then
            romcfg=`cat "$romcfgpath"`
            retroarch_core=`get_info_value "$romcfg" core`
            corepath=".retroarch/cores/$retroarch_core.so"

            echo "per game core: $retroarch_core" >> $sysdir/logs/game_list_options.log

            if [ -f "$corepath" ]; then
                if echo "$cmd" | grep -q "$sysdir/reset.cfg"; then
                    echo "LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so ./retroarch -v --appendconfig \"$sysdir/reset.cfg\" -L \"$corepath\" \"$rompath\"" > $sysdir/cmd_to_run.sh
                else
                    echo "LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so ./retroarch -v -L \"$corepath\" \"$rompath\"" > $sysdir/cmd_to_run.sh
                fi
            fi
        fi

        # Handle dollar sign
        if echo "$rompath" | grep -q "\$"; then
            temp=`cat $sysdir/cmd_to_run.sh`
            echo "$temp" | sed 's/\$/\\\$/g' > $sysdir/cmd_to_run.sh
        fi

        playActivity "init"
    fi

    echo "----- COMMAND:"
    cat $sysdir/cmd_to_run.sh

    if [ "$romext" == "miyoocmd" ]; then
        if [ -f "$rompath" ]; then
            emupath=`dirname $(echo "$cmd" | awk '{ gsub(/"/, "", $2); st = index($2,".."); if (st) { print substr($2,0,st) } else { print $2 } }')`
            cd "$emupath"

            chmod a+x "$rompath"
            "$rompath" "$rompath" "$emupath"
            retval=$?
        else
            retval=1
        fi
    else
        # GAME LAUNCH
        cd /mnt/SDCARD/RetroArch/
        $sysdir/cmd_to_run.sh
        retval=$?
    fi

    echo "cmd retval: $retval"

    if [ $retval -ge 128 ] && [ $retval -ne 143 ] && [ $retval -ne 255 ]; then
        cd $sysdir
        infoPanel --title "Fatal error occurred" --message "The program exited unexpectedly.\n(Error code: $retval)" --auto
    fi

    # TIMER END + SHUTDOWN CHECK
    if [ $is_game -eq 1 ]; then
        if echo "$cmd" | grep -q "$sysdir/reset.cfg"; then
            echo "$cmd" | sed 's/ --appendconfig \"\/mnt\/SDCARD\/.tmp_update\/reset.cfg\"//g' > $sysdir/cmd_to_run.sh
        fi

        cd $sysdir
        playActivity "$cmd"
        
        echo "game" > /tmp/prev_state
        check_off_order "End_Save"
    else
        echo "app" > /tmp/prev_state
        check_off_order "End"
    fi
}

get_info_value() {
    echo "$1" | grep "$2\b" | awk '{split($0,a,"="); print a[2]}' | awk -F'"' '{print $2}' | tr -d '\n'
}

check_switcher() {
    if [ -f $sysdir/.runGameSwitcher ] ; then
        launch_switcher
    elif [ -f /tmp/quick_switch ]; then
        # Quick switch
        rm -f /tmp/quick_switch
    else
        # Return to MainUI
        rm $sysdir/cmd_to_run.sh 2> /dev/null
        sync
    fi
    
    check_off_order "End"
}

launch_switcher() {
    cd $sysdir
    LD_PRELOAD="/mnt/SDCARD/miyoo/lib/libpadsp.so" gameSwitcher
    rm $sysdir/.runGameSwitcher
    echo "switcher" > /tmp/prev_state
    sync
}

check_off_order() {
    if  [ -f /tmp/.offOrder ] ; then
        cd $sysdir
        bootScreen "$1"

        killall tee
        rm -f /mnt/SDCARD/update.log
        
        sync
        reboot
        sleep 10
    fi
}

recentlist=/mnt/SDCARD/Roms/recentlist.json
recentlist_hidden=/mnt/SDCARD/Roms/recentlist-hidden.json
recentlist_temp=/tmp/recentlist-temp.json

check_hide_recents() {
    # Hide recents on
    if [ ! -f $sysdir/config/.showRecents ]; then
        # Hide recents by removing the json file
        if [ -f $recentlist ]; then
            cat $recentlist $recentlist_hidden > $recentlist_temp
            mv -f $recentlist_temp $recentlist_hidden
            rm -f $recentlist
        fi
    # Hide recents off
    else
        # Restore recentlist 
        if [ -f $recentlist_hidden ]; then
            cat $recentlist $recentlist_hidden > $recentlist_temp
            mv -f $recentlist_temp $recentlist
            rm -f $recentlist_hidden
        fi
    fi
    sync
}

clean_flag=/mnt/SDCARD/miyoo/app/.isClean
expert_flag=/mnt/SDCARD/miyoo/app/.isExpert

check_hide_expert() {
    if [ ! -f $sysdir/config/.showExpert ]; then
        # Should be clean
        if [ ! -f $clean_flag ] || [ -f $expert_flag ]; then
            rm /mnt/SDCARD/miyoo/app/MainUI
            rm -f $expert_flag
	        cp $sysdir/bin/MainUI-clean /mnt/SDCARD/miyoo/app/MainUI
            touch $clean_flag
        fi
    else
        # Should be expert
        if [ ! -f $expert_flag ] || [ -f $clean_flag ]; then
            rm /mnt/SDCARD/miyoo/app/MainUI
            rm -f $clean_flag
	        cp $sysdir/bin/MainUI-expert /mnt/SDCARD/miyoo/app/MainUI
            touch $expert_flag
        fi
    fi
    sync
}

init_system() {
    # init_lcd
    cat /proc/ls
    sleep 0.25
    
    /mnt/SDCARD/miyoo/app/audioserver &

    # init charger detection
    if [ ! -f /sys/devices/gpiochip0/gpio/gpio59/direction ]; then
        echo 59 > /sys/class/gpio/export
        echo in > /sys/devices/gpiochip0/gpio/gpio59/direction
    fi

    # init backlight
    echo 0 > /sys/class/pwm/pwmchip0/export
    echo 800 > /sys/class/pwm/pwmchip0/pwm0/period
    echo 80 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle
    echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable
}

update_time() {
    timepath=/mnt/SDCARD/Saves/CurrentProfile/saves/currentTime.txt
    currentTime=0
    # Load current time
    if [ -f $timepath ]; then
        currentTime=`cat $timepath`
    fi
    #Add 4 hours to the current time
    hours=4
    if [ -f $sysdir/config/startup/addHours ]; then
        hours=`cat $sysdir/config/startup/addHours`
    fi
    addTime=$(($hours * 3600))
    currentTime=$(($currentTime + $addTime))
    date +%s -s @$currentTime
}

set_startup_tab() {
    startup_tab=0
    if [ -f $sysdir/config/startup/tab ]; then
        startup_tab=`cat $sysdir/config/startup/tab`
    fi
    
    cd $sysdir
    setState "$startup_tab"
}

main
