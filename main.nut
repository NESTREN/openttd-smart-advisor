class OpenTTDSmart extends GSController {
    company_pages = null;
    passenger_cargo_id = -1;
    initial_page_shown = false;

    function Start() {
        GSLog.Info("OpenTTD Smart Advisor started.");
        this.company_pages = {};
        this.passenger_cargo_id = this.FindPassengerCargo();

        if (this.passenger_cargo_id < 0) {
            GSLog.Warning("Passenger cargo was not found. Route ideas will be disabled.");
        }

        local last_refresh = GSDate.DATE_INVALID;
        while (true) {
            local now = GSDate.GetCurrentDate();
            if (last_refresh == GSDate.DATE_INVALID || (now - last_refresh) >= this.GetSettingInt("refresh_days", 30, 7, 120)) {
                this.RefreshAllCompanies();
                last_refresh = now;
            }

            this.Sleep(74); // roughly one in-game day
        }
    }

    function RefreshAllCompanies() {
        local companies = this.GetActiveCompanies();
        if (companies.len() == 0) return;

        local auto_show = this.GetSettingBool("auto_show_page", true);

        foreach (company in companies) {
            local page_state = this.EnsureCompanyPage(company);
            if (page_state == null) continue;

            local analysis = this.BuildCompanyAnalysis(company);
            this.UpdateCompanyPage(page_state, analysis);

            if (auto_show && !this.initial_page_shown) {
                GSStoryPage.Show(page_state.page_id);
                this.initial_page_shown = true;
            }
        }
    }

    function BuildCompanyAnalysis(company) {
        local mode_stats = this.CreateModeStats();
        local route_tables = { rail = {}, road = {}, water = {} };

        local bank = GSCompany.GetBankBalance(company);
        local loan = 0;
        local max_loan = 0;
        local route_ideas = [];

        local top_limit = this.GetSettingInt("top_routes", 5, 3, 12);
        local town_limit = this.GetSettingInt("town_candidates", 18, 8, 40);

        {
            local cm = GSCompanyMode(company);
            if (GSCompanyMode.IsValid()) {
                loan = GSCompany.GetLoanAmount();
                max_loan = GSCompany.GetMaxLoanAmount();
                this.CollectVehicleAndRouteStats(mode_stats, route_tables);

                local available_financing = bank + (max_loan - loan);
                local towns = this.GetTopTownCandidates(town_limit);
                route_ideas = this.GenerateRouteIdeas(mode_stats, towns, available_financing, top_limit);
            }
        }

        local infra = this.GetInfrastructureCosts(company);
        local quarters = this.GetQuarterSummary(company);

        local capabilities = {};
        capabilities.bank <- bank;
        capabilities.loan <- loan;
        capabilities.max_loan <- max_loan;
        capabilities.free_credit <- max_loan - loan;
        capabilities.available_financing <- bank + capabilities.free_credit;

        local mode_opex = {};
        mode_opex.rail <- mode_stats.rail.running + (infra.rail + infra.signals) * 12;
        mode_opex.road <- mode_stats.road.running + infra.road * 12;
        mode_opex.water <- mode_stats.water.running + infra.canal * 12;
        mode_opex.other <- (infra.station + infra.airport) * 12;

        local analysis = {};
        analysis.company_id <- company;
        analysis.company_name <- GSCompany.GetName(company);
        analysis.capabilities <- capabilities;
        analysis.mode_stats <- mode_stats;
        analysis.mode_opex <- mode_opex;
        analysis.infrastructure <- infra;
        analysis.quarters <- quarters;
        analysis.top_routes <- this.BuildTopRoutes(route_tables, top_limit);
        analysis.route_ideas <- route_ideas;
        analysis.date <- GSDate.GetCurrentDate();

        return analysis;
    }

    function CreateModeStats() {
        local stats = {};

        stats.rail <- { label = "Rail", vehicles = 0, profit = 0, running = 0 };
        stats.road <- { label = "Road", vehicles = 0, profit = 0, running = 0 };
        stats.water <- { label = "Water", vehicles = 0, profit = 0, running = 0 };

        return stats;
    }

    function CollectVehicleAndRouteStats(mode_stats, route_tables) {
        local vehicles = GSVehicleList();
        for (local vehicle = vehicles.Begin(); !vehicles.IsEnd(); vehicle = vehicles.Next()) {
            if (!GSVehicle.IsPrimaryVehicle(vehicle)) continue;

            local mode_key = this.ModeFromVehicleType(GSVehicle.GetVehicleType(vehicle));
            if (mode_key == null) continue;

            local profit = GSVehicle.GetProfitLastYear(vehicle);
            local running = GSVehicle.GetRunningCost(vehicle);
            local mode_data = mode_stats[mode_key];
            mode_data.vehicles += 1;
            mode_data.profit += profit;
            mode_data.running += running;

            local route = this.ExtractVehicleRoute(vehicle);
            if (route == null) continue;

            local mode_routes = route_tables[mode_key];
            if (!(route.key in mode_routes)) {
                mode_routes[route.key] <- {
                    name = route.name,
                    vehicles = 0,
                    profit = 0,
                    running = 0,
                    tile = route.tile
                };
            }

            local route_data = mode_routes[route.key];
            route_data.vehicles += 1;
            route_data.profit += profit;
            route_data.running += running;
        }
    }

    function BuildTopRoutes(route_tables, top_limit) {
        local top = [];
        foreach (mode_key, mode_routes in route_tables) {
            foreach (route_key, route_data in mode_routes) {
                local item = {};
                item.mode <- this.ModeLabel(mode_key);
                item.name <- route_data.name;
                item.vehicles <- route_data.vehicles;
                item.profit <- route_data.profit;
                item.running <- route_data.running;
                item.tile <- route_data.tile;
                item.score <- route_data.profit;

                this.InsertTopItem(top, item, top_limit, "score");
            }
        }

        return top;
    }

    function ExtractVehicleRoute(vehicle) {
        local order_count = GSOrder.GetOrderCount(vehicle);
        if (order_count < 2) return null;

        local first_station = GSStation.STATION_INVALID;
        local last_station = GSStation.STATION_INVALID;

        for (local i = 0; i < order_count; i++) {
            if (!GSOrder.IsGotoStationOrder(vehicle, i)) continue;

            local destination = GSOrder.GetOrderDestination(vehicle, i);
            local station = GSStation.GetStationID(destination);
            if (!GSStation.IsValidStation(station)) continue;

            if (first_station == GSStation.STATION_INVALID) first_station = station;
            last_station = station;
        }

        if (first_station == GSStation.STATION_INVALID) return null;
        if (last_station == GSStation.STATION_INVALID) return null;
        if (first_station == last_station) return null;

        local a = (first_station < last_station) ? first_station : last_station;
        local b = (first_station < last_station) ? last_station : first_station;

        local route = {};
        route.key <- a.tostring() + ":" + b.tostring();
        route.name <- GSStation.GetName(first_station) + " <-> " + GSStation.GetName(last_station);
        route.tile <- GSStation.GetLocation(first_station);

        return route;
    }

    function GenerateRouteIdeas(mode_stats, towns, available_financing, top_limit) {
        local all_ideas = [];
        if (this.passenger_cargo_id < 0) return all_ideas;
        if (towns.len() < 2) return all_ideas;

        local water_cache = {};

        for (local i = 0; i < towns.len(); i++) {
            for (local j = i + 1; j < towns.len(); j++) {
                local a = towns[i];
                local b = towns[j];
                local distance = GSMap.DistanceManhattan(a.tile, b.tile);
                if (distance < 8) continue;

                local demand = this.EstimateTownDemand(a.population, b.population);
                if (demand <= 0) continue;

                if (distance >= 30) {
                    this.TryAppendRouteIdea(all_ideas, "rail", a, b, distance, demand, mode_stats.rail, available_financing);
                }

                if (distance >= 8 && distance <= 130) {
                    this.TryAppendRouteIdea(all_ideas, "road", a, b, distance, demand, mode_stats.road, available_financing);
                }

                if (distance >= 24) {
                    local has_water_a = this.HasTownWaterAccessCached(a, water_cache);
                    local has_water_b = this.HasTownWaterAccessCached(b, water_cache);
                    if (has_water_a && has_water_b) {
                        this.TryAppendRouteIdea(all_ideas, "water", a, b, distance, demand, mode_stats.water, available_financing);
                    }
                }
            }
        }

        local top = [];
        foreach (idea in all_ideas) {
            this.InsertTopItem(top, idea, top_limit, "score");
        }

        return top;
    }

    function TryAppendRouteIdea(target, mode_key, town_a, town_b, distance, demand, mode_stat, available_financing) {
        local build_cost = this.EstimateBuildCost(mode_key, distance);
        if (build_cost <= 0) return;

        local annual_revenue = this.EstimateAnnualRevenue(mode_key, distance, demand);
        local annual_cost = this.EstimateAnnualOperatingCost(mode_key, distance, build_cost, mode_stat);
        local annual_profit = annual_revenue - annual_cost;

        local roi_years = 9999.0;
        if (annual_profit > 0) {
            roi_years = build_cost.tofloat() / annual_profit.tofloat();
        }

        local affordable = available_financing >= build_cost;

        local score = annual_profit.tofloat();
        if (!affordable) score -= (build_cost - available_financing).tofloat() * 0.25;
        if (annual_profit <= 0) score -= 1000000.0;

        local idea = {};
        idea.mode <- this.ModeLabel(mode_key);
        idea.mode_key <- mode_key;
        idea.name <- town_a.name + " - " + town_b.name;
        idea.distance <- distance;
        idea.build_cost <- build_cost;
        idea.annual_revenue <- annual_revenue;
        idea.annual_cost <- annual_cost;
        idea.annual_profit <- annual_profit;
        idea.roi_years <- roi_years;
        idea.affordable <- affordable;
        idea.tile <- this.GetMidpointTile(town_a.tile, town_b.tile);
        idea.score <- score;

        target.append(idea);
    }

    function EstimateBuildCost(mode_key, distance) {
        if (mode_key == "rail") {
            local rail_type = GSRail.GetCurrentRailType();
            if (!GSRail.IsRailTypeAvailable(rail_type)) {
                local rail_types = GSRailTypeList();
                local first_rail_type = rail_types.Begin();
                if (!rail_types.IsEnd()) rail_type = first_rail_type;
            }
            if (!GSRail.IsRailTypeAvailable(rail_type)) {
                return distance * 3600 + 220000;
            }

            local track = GSRail.GetBuildCost(rail_type, GSRail.BT_TRACK);
            local station = GSRail.GetBuildCost(rail_type, GSRail.BT_STATION);
            local depot = GSRail.GetBuildCost(rail_type, GSRail.BT_DEPOT);
            local signal = GSRail.GetBuildCost(rail_type, GSRail.BT_SIGNAL);

            return track * (distance + 20) * 2 + station * 6 + depot * 2 + signal * (distance / 5 + 4);
        }

        if (mode_key == "road") {
            local road_type = GSRoad.GetCurrentRoadType();
            if (!GSRoad.IsRoadTypeAvailable(road_type)) {
                local road_types = GSRoadTypeList(GSRoad.ROADTRAMTYPES_ROAD);
                local first_road_type = road_types.Begin();
                if (!road_types.IsEnd()) road_type = first_road_type;
            }
            if (!GSRoad.IsRoadTypeAvailable(road_type)) {
                return distance * 1500 + 70000;
            }

            local road_piece = GSRoad.GetBuildCost(road_type, GSRoad.BT_ROAD);
            local bus_stop = GSRoad.GetBuildCost(road_type, GSRoad.BT_BUS_STOP);
            local depot = GSRoad.GetBuildCost(road_type, GSRoad.BT_DEPOT);

            return road_piece * (distance + 12) * 2 + bus_stop * 4 + depot * 2;
        }

        local dock = GSMarine.GetBuildCost(GSMarine.BT_DOCK);
        local depot = GSMarine.GetBuildCost(GSMarine.BT_DEPOT);
        local buoy = GSMarine.GetBuildCost(GSMarine.BT_BUOY);
        local canal = GSMarine.GetBuildCost(GSMarine.BT_CANAL);

        return dock * 2 + depot + buoy * (distance / 20 + 3) + canal * (distance / 6);
    }

    function EstimateAnnualRevenue(mode_key, distance, demand) {
        local monthly_demand_factor = 0.05;
        local transit_days = 8;

        if (mode_key == "rail") {
            monthly_demand_factor = 0.075;
            transit_days = this.MaxInt(5, distance / 11);
        } else if (mode_key == "road") {
            monthly_demand_factor = 0.05;
            transit_days = this.MaxInt(8, distance / 7);
        } else {
            monthly_demand_factor = 0.038;
            transit_days = this.MaxInt(13, distance / 4);
        }

        local monthly_units = demand * monthly_demand_factor;
        local unit_income = GSCargo.GetCargoIncome(this.passenger_cargo_id, distance, transit_days);
        local yearly = unit_income.tofloat() * monthly_units * 12.0 * 0.72;
        if (yearly < 0) yearly = 0;

        return yearly.tointeger();
    }

    function EstimateAnnualOperatingCost(mode_key, distance, build_cost, mode_stat) {
        local avg_running = 0.0;
        if (mode_stat.vehicles > 0) {
            avg_running = mode_stat.running.tofloat() / mode_stat.vehicles.tofloat();
        }

        local vehicles_needed = 2;
        local fallback_running_factor = 0.09;
        local infra_factor = 0.03;

        if (mode_key == "rail") {
            vehicles_needed = this.MaxInt(2, distance / 55 + 1);
            fallback_running_factor = 0.09;
            infra_factor = 0.03;
        } else if (mode_key == "road") {
            vehicles_needed = this.MaxInt(4, distance / 35 + 1);
            fallback_running_factor = 0.13;
            infra_factor = 0.02;
        } else {
            vehicles_needed = this.MaxInt(2, distance / 120 + 1);
            fallback_running_factor = 0.07;
            infra_factor = 0.015;
        }

        if (avg_running <= 0) {
            avg_running = build_cost.tofloat() * fallback_running_factor;
        }

        local running = avg_running * vehicles_needed.tofloat();
        local infra = build_cost.tofloat() * infra_factor;

        return (running + infra).tointeger();
    }

    function EstimateTownDemand(pop_a, pop_b) {
        local total_pop = pop_a + pop_b;
        local demand = total_pop.tofloat() * 0.08;
        if (demand < 20.0) demand = 20.0;
        return demand;
    }

    function GetTopTownCandidates(limit) {
        local towns = GSTownList();
        local result = [];

        if (towns.Count() == 0) return result;

        towns.Valuate(GSTown.GetPopulation);
        towns.Sort(GSList.SORT_BY_VALUE, GSList.SORT_DESCENDING);
        towns.KeepTop(limit);

        for (local town = towns.Begin(); !towns.IsEnd(); town = towns.Next()) {
            local population = towns.GetValue(town);
            if (population <= 0) continue;

            result.append({
                id = town,
                name = GSTown.GetName(town),
                population = population,
                tile = GSTown.GetLocation(town)
            });
        }

        return result;
    }

    function HasTownWaterAccessCached(town, cache) {
        local key = town.id.tostring();
        if (key in cache) return cache[key];

        local access = this.HasWaterNearby(town.tile, 9);
        cache[key] <- access;
        return access;
    }

    function HasWaterNearby(tile, radius) {
        local tx = GSMap.GetTileX(tile);
        local ty = GSMap.GetTileY(tile);

        local min_x = this.MaxInt(0, tx - radius);
        local max_x = this.MinInt(GSMap.GetMapSizeX() - 1, tx + radius);
        local min_y = this.MaxInt(0, ty - radius);
        local max_y = this.MinInt(GSMap.GetMapSizeY() - 1, ty + radius);

        for (local x = min_x; x <= max_x; x++) {
            for (local y = min_y; y <= max_y; y++) {
                local test_tile = GSMap.GetTileIndex(x, y);
                if (GSTile.HasTransportType(test_tile, GSTile.TRANSPORT_WATER)) {
                    return true;
                }
            }
        }

        return false;
    }

    function GetInfrastructureCosts(company) {
        local infra = {};

        infra.rail <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_RAIL);
        infra.road <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_ROAD);
        infra.canal <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_CANAL);
        infra.station <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_STATION);
        infra.airport <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_AIRPORT);
        infra.signals <- GSInfrastructure.GetMonthlyInfrastructureCosts(company, GSInfrastructure.INFRASTRUCTURE_SIGNALS);

        infra.total_monthly <- infra.rail + infra.road + infra.canal + infra.station + infra.airport + infra.signals;
        infra.total_yearly <- infra.total_monthly * 12;

        return infra;
    }

    function GetQuarterSummary(company) {
        local total_income = 0;
        local total_expenses = 0;
        local samples = 0;

        local q = GSCompany.CURRENT_QUARTER;
        local step = (GSCompany.CURRENT_QUARTER <= GSCompany.EARLIEST_QUARTER) ? 1 : -1;

        while (true) {
            total_income += GSCompany.GetQuarterlyIncome(company, q);
            total_expenses += GSCompany.GetQuarterlyExpenses(company, q);
            samples++;

            if (samples >= 4) break;
            if (q == GSCompany.EARLIEST_QUARTER) break;
            q += step;
        }

        if (samples <= 0) samples = 1;

        local avg_income = (total_income.tofloat() / samples.tofloat()).tointeger();
        local avg_expenses = (total_expenses.tofloat() / samples.tofloat()).tointeger();

        local summary = {};
        summary.samples <- samples;
        summary.avg_income <- avg_income;
        summary.avg_expenses <- avg_expenses;
        summary.annual_income <- avg_income * 4;
        summary.annual_expenses <- avg_expenses * 4;

        return summary;
    }

    function EnsureCompanyPage(company) {
        local key = company.tostring();
        if (key in this.company_pages) {
            local existing = this.company_pages[key];
            if (GSStoryPage.IsValidStoryPage(existing.page_id)) return existing;
        }

        local fallback_tile = this.GetFallbackTile(company);
        local title = "OpenTTD Smart Advisor - " + GSCompany.GetName(company);
        local page_id = GSStoryPage.New(company, title);
        if (!GSStoryPage.IsValidStoryPage(page_id)) {
            GSLog.Warning("Failed to create Story Book page for company " + company);
            return null;
        }

        local state = {};
        state.company <- company;
        state.page_id <- page_id;
        state.fallback_tile <- fallback_tile;
        state.summary_id <- GSStoryPage.NewElement(page_id, GSStoryPage.SPET_TEXT, 0, "Preparing financial snapshot...");
        state.fleet_id <- GSStoryPage.NewElement(page_id, GSStoryPage.SPET_TEXT, 0, "Preparing mode profitability...");
        state.routes_id <- GSStoryPage.NewElement(page_id, GSStoryPage.SPET_TEXT, 0, "Preparing top route list...");
        state.ideas_id <- GSStoryPage.NewElement(page_id, GSStoryPage.SPET_TEXT, 0, "Preparing route ideas...");
        state.location_ids <- [];

        for (local i = 0; i < 3; i++) {
            state.location_ids.append(
                GSStoryPage.NewElement(page_id, GSStoryPage.SPET_LOCATION, fallback_tile, "No route idea available yet.")
            );
        }

        this.company_pages[key] <- state;
        return state;
    }

    function UpdateCompanyPage(state, analysis) {
        GSStoryPage.SetTitle(state.page_id, "OpenTTD Smart Advisor - " + analysis.company_name);
        GSStoryPage.SetDate(state.page_id, analysis.date);

        GSStoryPage.UpdateElement(state.summary_id, 0, this.BuildSummaryText(analysis));
        GSStoryPage.UpdateElement(state.fleet_id, 0, this.BuildFleetText(analysis));
        GSStoryPage.UpdateElement(state.routes_id, 0, this.BuildTopRoutesText(analysis.top_routes));
        GSStoryPage.UpdateElement(state.ideas_id, 0, this.BuildIdeasText(analysis.route_ideas));

        for (local i = 0; i < state.location_ids.len(); i++) {
            local element_id = state.location_ids[i];
            if (i < analysis.route_ideas.len()) {
                local idea = analysis.route_ideas[i];
                local location_text =
                    "[" + idea.mode + "] " + idea.name +
                    " | build " + this.FormatMoney(idea.build_cost) +
                    " | profit/y " + this.FormatMoney(idea.annual_profit) +
                    " | ROI " + this.FormatYears(idea.roi_years);
                GSStoryPage.UpdateElement(element_id, idea.tile, location_text);
            } else {
                GSStoryPage.UpdateElement(element_id, state.fallback_tile, "No additional high-confidence route idea.");
            }
        }
    }

    function BuildSummaryText(analysis) {
        local c = analysis.capabilities;
        local q = analysis.quarters;
        local i = analysis.infrastructure;

        local text = "";
        text += "Financial capability\n";
        text += "Cash: " + this.FormatMoney(c.bank);
        text += " | Loan: " + this.FormatMoney(c.loan) + " / " + this.FormatMoney(c.max_loan) + "\n";
        text += "Available financing (cash + free credit): " + this.FormatMoney(c.available_financing) + "\n";
        text += "Average quarter income: " + this.FormatMoney(q.avg_income);
        text += " | Average quarter expenses: " + this.FormatMoney(q.avg_expenses) + "\n";
        text += "Annualized income: " + this.FormatMoney(q.annual_income);
        text += " | Annualized expenses: " + this.FormatMoney(q.annual_expenses) + "\n";
        text += "Monthly infrastructure costs: rail " + this.FormatMoney(i.rail);
        text += ", road " + this.FormatMoney(i.road);
        text += ", canal " + this.FormatMoney(i.canal);
        text += ", station " + this.FormatMoney(i.station);
        text += ", airport " + this.FormatMoney(i.airport);
        text += ", signals " + this.FormatMoney(i.signals);

        return text;
    }

    function BuildFleetText(analysis) {
        local stats = analysis.mode_stats;
        local opex = analysis.mode_opex;

        local text = "Mode profitability (last economy-year)\n";
        text += this.BuildModeLine("Rail", stats.rail, opex.rail) + "\n";
        text += this.BuildModeLine("Road", stats.road, opex.road) + "\n";
        text += this.BuildModeLine("Water", stats.water, opex.water) + "\n";
        text += "Unallocated infra opex/y (stations + airports): " + this.FormatMoney(opex.other);

        return text;
    }

    function BuildModeLine(label, mode_data, annual_opex) {
        local line = label + ": vehicles " + mode_data.vehicles;
        line += " | profit " + this.FormatMoney(mode_data.profit);
        line += " | running " + this.FormatMoney(mode_data.running);
        line += " | margin " + this.FormatPercent(mode_data.profit, mode_data.running);
        line += " | est opex/y " + this.FormatMoney(annual_opex);
        return line;
    }

    function BuildTopRoutesText(top_routes) {
        local text = "Top active routes by profit\n";
        if (top_routes.len() == 0) {
            text += "No route with at least two station orders was detected.";
            return text;
        }

        for (local i = 0; i < top_routes.len(); i++) {
            local route = top_routes[i];
            text += (i + 1) + ". ";
            text += "[" + route.mode + "] " + route.name;
            text += " | vehicles " + route.vehicles;
            text += " | profit " + this.FormatMoney(route.profit);
            text += " | margin " + this.FormatPercent(route.profit, route.running) + "\n";
        }

        return text;
    }

    function BuildIdeasText(route_ideas) {
        local text = "Top suggested new routes (estimated)\n";
        if (route_ideas.len() == 0) {
            text += "No high-confidence route idea. Increase town_candidates or wait for town growth.";
            return text;
        }

        for (local i = 0; i < route_ideas.len(); i++) {
            local idea = route_ideas[i];
            text += (i + 1) + ". ";
            text += "[" + idea.mode + "] " + idea.name;
            text += " | dist " + idea.distance;
            text += " | build " + this.FormatMoney(idea.build_cost);
            text += " | rev/y " + this.FormatMoney(idea.annual_revenue);
            text += " | opex/y " + this.FormatMoney(idea.annual_cost);
            text += " | profit/y " + this.FormatMoney(idea.annual_profit);
            text += " | ROI " + this.FormatYears(idea.roi_years);
            text += " | affordable " + (idea.affordable ? "yes" : "no") + "\n";
        }

        return text;
    }

    function InsertTopItem(list, item, limit, field_name) {
        local position = list.len();
        for (local i = 0; i < list.len(); i++) {
            if (item[field_name] > list[i][field_name]) {
                position = i;
                break;
            }
        }

        list.insert(position, item);
        if (list.len() > limit) list.pop();
    }

    function FindPassengerCargo() {
        local cargos = GSCargoList();
        for (local cargo = cargos.Begin(); !cargos.IsEnd(); cargo = cargos.Next()) {
            if (GSCargo.HasCargoClass(cargo, GSCargo.CC_PASSENGERS)) return cargo;
        }
        return -1;
    }

    function GetActiveCompanies() {
        local companies = [];
        for (local company = GSCompany.COMPANY_FIRST; company <= GSCompany.COMPANY_LAST; company++) {
            local resolved = GSCompany.ResolveCompanyID(company);
            if (resolved == GSCompany.COMPANY_INVALID) continue;
            companies.append(resolved);
        }
        return companies;
    }

    function ModeFromVehicleType(vehicle_type) {
        if (vehicle_type == GSVehicle.VT_RAIL) return "rail";
        if (vehicle_type == GSVehicle.VT_ROAD) return "road";
        if (vehicle_type == GSVehicle.VT_WATER) return "water";
        return null;
    }

    function ModeLabel(mode_key) {
        if (mode_key == "rail") return "Rail";
        if (mode_key == "road") return "Road";
        return "Water";
    }

    function GetMidpointTile(tile_a, tile_b) {
        local x = (GSMap.GetTileX(tile_a) + GSMap.GetTileX(tile_b)) / 2;
        local y = (GSMap.GetTileY(tile_a) + GSMap.GetTileY(tile_b)) / 2;
        local mid = GSMap.GetTileIndex(x, y);
        if (GSMap.IsValidTile(mid)) return mid;
        return tile_a;
    }

    function GetFallbackTile(company) {
        local hq_tile = GSCompany.GetCompanyHQ(company);
        if (GSMap.IsValidTile(hq_tile)) return hq_tile;

        local towns = GSTownList();
        local first_town = towns.Begin();
        if (!towns.IsEnd()) {
            return GSTown.GetLocation(first_town);
        }

        return GSMap.GetTileIndex(0, 0);
    }

    function FormatMoney(value) {
        local negative = value < 0;
        if (negative) value = -value;

        local s = value.tostring();
        local out = "";
        local group = 0;
        for (local i = s.len() - 1; i >= 0; i--) {
            out = s.slice(i, i + 1) + out;
            group++;
            if (group == 3 && i > 0) {
                out = " " + out;
                group = 0;
            }
        }

        if (negative) return "-$" + out;
        return "$" + out;
    }

    function FormatPercent(numerator, denominator) {
        if (denominator <= 0) return "n/a";
        local pct = (numerator.tofloat() * 100.0) / denominator.tofloat();
        return this.FormatOneDecimal(pct) + "%";
    }

    function FormatYears(years) {
        if (years >= 9999.0) return "n/a";
        return this.FormatOneDecimal(years) + "y";
    }

    function FormatOneDecimal(value) {
        local scaled = (value * 10.0).tointeger();
        local int_part = (scaled / 10).tointeger();
        local frac = scaled - int_part * 10;
        if (frac < 0) frac = -frac;
        return int_part.tostring() + "." + frac.tostring();
    }

    function GetSettingInt(name, fallback, min_value, max_value) {
        local value = GSController.GetSetting(name);
        if (value < min_value) value = min_value;
        if (value > max_value) value = max_value;
        if (value == 0 && fallback != 0) return fallback;
        return value;
    }

    function GetSettingBool(name, fallback) {
        local value = GSController.GetSetting(name);
        if (value == 0) return false;
        if (value == 1) return true;
        return fallback;
    }

    function MinInt(a, b) {
        return (a < b) ? a : b;
    }

    function MaxInt(a, b) {
        return (a > b) ? a : b;
    }
}
