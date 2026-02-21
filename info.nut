class OpenTTDSmartInfo extends GSInfo {
    function GetAuthor()      { return "nestren"; }
    function GetName()        { return "OpenTTD Smart Advisor"; }
    function GetShortName()   { return "OTSA"; }
    function GetDescription() { return "Advanced profitability analytics and route planning for rail, road and water transport."; }
    function GetVersion()     { return 1; }
    function MinVersionToLoad() { return 1; }
    function GetDate()        { return "2026-02-21"; }
    function CreateInstance() { return "OpenTTDSmart"; }
    function GetAPIVersion()  { return "15"; }
    function GetURL()         { return "https://github.com/NESTREN/openttd-smart-advisor"; }

    function GetSettings() {
        this.AddSetting({
            name = "refresh_days",
            description = "Days between automatic analytics refreshes.",
            easy_value = 30,
            medium_value = 21,
            hard_value = 14,
            custom_value = 30,
            min_value = 7,
            max_value = 120,
            flags = GSInfo.CONFIG_INGAME
        });

        this.AddSetting({
            name = "top_routes",
            description = "How many top routes and ideas to show in reports.",
            easy_value = 5,
            medium_value = 7,
            hard_value = 10,
            custom_value = 5,
            min_value = 3,
            max_value = 12,
            flags = GSInfo.CONFIG_INGAME
        });

        this.AddSetting({
            name = "town_candidates",
            description = "How many largest towns are scanned for new route ideas.",
            easy_value = 14,
            medium_value = 20,
            hard_value = 28,
            custom_value = 18,
            min_value = 8,
            max_value = 40,
            flags = GSInfo.CONFIG_INGAME
        });

        this.AddSetting({
            name = "auto_show_page",
            description = "Open Story Book page automatically after first analysis.",
            easy_value = 1,
            medium_value = 1,
            hard_value = 0,
            custom_value = 1,
            min_value = 0,
            max_value = 1,
            flags = GSInfo.CONFIG_BOOLEAN | GSInfo.CONFIG_INGAME
        });
    }
}

RegisterGS(OpenTTDSmartInfo());
