// Copyright (c) Tamago Blockchain Labs, Inc.
// SPDX-License-Identifier: MIT

module legato::vault {

    // use std::debug;

    use sui::object::{ Self, ID, UID }; 
    use sui::balance::{  Self, Supply, Balance};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI; 
    use sui::transfer;
    use sui::bag::{Self,  Bag};
    // use sui::url::{Self};
    use sui::tx_context::{Self, TxContext};

    // use std::option::{Self};
    use std::string::{  String }; 
    use std::vector;

    use sui_system::staking_pool::{ Self, StakedSui};
    use sui_system::sui_system::{ Self, SuiSystemState };

    use legato::vault_lib::{token_to_name, calculate_pt_debt_from_epoch, sort_items};
    use legato::amm::{ Self, AMMGlobal};
    use legato::event::{new_vault_event, mint_event, migrate_event, redeem_event, exit_event};
    use legato::apy_reader::{Self}; 
     

    // ======== Constants ========
    const MIN_VAULT_SPAN: u64 = 30; // each vault's start epoch and maturity should last at least 30 epochs
    const YT_TOTAL_SUPPLY: u64 = 100_000_000 * 1_000_000_000; // 100 Mil. 
    const MIST_PER_SUI : u64 = 1_000_000_000;
    const COOLDOWN_EPOCH: u64 = 3;
    const MIN_SUI_TO_STAKE : u64 = 1_000_000_000; // 1 Sui
    const MIN_PT_TO_MIGRATE : u64 = 1_000_000_000; // 1 P
    const MIN_PT_TO_REDEEM: u64 = 1_000_000_000; // 1 PT
    const MIN_YT_FOR_EXIT: u64 = 1_000_000_000; // 1 YT

    // ======== Errors ========
    const E_DUPLICATED_ENTRY: u64 = 1;
    const E_NOT_FOUND: u64 = 2;
    const E_INVALID_STARTED: u64 = 3;
    const E_TOO_SHORT: u64 = 4;
    const E_INVALID_MATURITY: u64 = 5;
    const E_PAUSED_STATE: u64 = 6;
    const E_NOT_ENABLED: u64 = 7;
    const E_VAULT_MATURED: u64 = 8;
    const E_VAULT_NOT_STARTED: u64 = 9;
    const E_MIN_THRESHOLD: u64 = 10;
    const E_NOT_REGISTERED: u64 = 11;
    const E_UNAUTHORIZED_POOL: u64 = 12;
    const E_VAULT_NOT_ORDER: u64 = 13;
    const E_VAULT_NOT_MATURED: u64 = 14;
    const E_INVALID_AMOUNT: u64 = 15;
    const E_EXIT_DISABLED: u64 = 16;
    const E_INVALID_DEPOSIT_ID: u64 = 17;
    const E_INSUFFICIENT_AMOUNT: u64 = 18;

    // ======== Structs =========

    struct PT_TOKEN<phantom P> has drop {}
    struct YT_TOKEN<phantom P> has drop {}

    // a fixed-term pool taking Staked SUI objects for fungible PT
    struct PoolConfig has store {
        started_epoch: u64,
        maturity_epoch: u64,
        vault_apy: u64,
        deposit_items: vector<StakedSui>,
        enable_mint: bool,
        enable_exit: bool
    }

    // keeps all assets for each pool
    struct PoolReserve<phantom P> has store {
        
        pt_supply: Supply<PT_TOKEN<P>>,
        yt_supply: Supply<YT_TOKEN<P>>
    }

    // a shared pool where the redemption process takes place
    struct RedemptionPool has store {
        pending_withdrawal: Balance<SUI>
    }

    struct Global has key {
        id: UID,
        staking_pools: vector<address>, // supported staking pools
        staking_pool_ids: vector<ID>, // supported staking pools in ID
        pool_list: vector<String>,
        pools: Table<String, PoolConfig>,
        pool_reserves: Bag,
        redemption_pool: RedemptionPool
    }

    // using ManagerCap for admin permission
    struct ManagerCap has key {
        id: UID
    }

    fun init(ctx: &mut TxContext) {
        
        transfer::transfer(
            ManagerCap {id: object::new(ctx)},
            tx_context::sender(ctx)
        );

        transfer::share_object(Global {
            id: object::new(ctx),
            staking_pools: vector::empty<address>(),
            staking_pool_ids: vector::empty<ID>(),
            pool_list: vector::empty<String>(),
            pools: table::new(ctx),
            pool_reserves: bag::new(ctx),
            redemption_pool: RedemptionPool {
                pending_withdrawal: balance::zero()
            }
        })

    }

    // ======== Public Functions =========

    // convert Staked SUI to PT
    public entry fun mint<P>(wrapper: &mut SuiSystemState, global: &mut Global, staked_sui: StakedSui, ctx: &mut TxContext) {
        check_not_paused(global, tx_context::epoch(ctx));

        let vault_config = get_vault_config<P>(&mut global.pools);
        let vault_reserve = get_vault_reserve<P>(&mut global.pool_reserves);

        assert!(vault_config.enable_mint == true, E_NOT_ENABLED);
        assert!(vault_config.maturity_epoch-COOLDOWN_EPOCH > tx_context::epoch(ctx), E_VAULT_MATURED);
        assert!(tx_context::epoch(ctx) >= vault_config.started_epoch, E_VAULT_NOT_STARTED);
        assert!(staking_pool::staked_sui_amount(&staked_sui) >= MIN_SUI_TO_STAKE, E_MIN_THRESHOLD);

        let pool_id = staking_pool::pool_id(&staked_sui);
        assert!(vector::contains(&global.staking_pool_ids, &pool_id), E_UNAUTHORIZED_POOL);

        let asset_object_id = object::id(&staked_sui);

        // Take the Staked SUI
        let principal_amount = staking_pool::staked_sui_amount(&staked_sui);
        let total_earnings = 
            if (tx_context::epoch(ctx) > staking_pool::stake_activation_epoch(&staked_sui))
                apy_reader::earnings_from_staked_sui(wrapper, &staked_sui, tx_context::epoch(ctx))
            else 0;
        
        receive_staked_sui(vault_config, staked_sui);

        // Calculate PT to send out
        let debt_amount = calculate_pt_debt_from_epoch(vault_config.vault_apy, tx_context::epoch(ctx), vault_config.maturity_epoch, principal_amount+total_earnings);
        let minted_pt_amount = principal_amount+total_earnings+debt_amount;

        // Mint PT to the user
        mint_pt<P>(vault_reserve, minted_pt_amount, ctx);

        // emit event
        mint_event(
            token_to_name<P>(),
            pool_id,
            principal_amount,
            minted_pt_amount, 
            asset_object_id,
            tx_context::sender(ctx),
            tx_context::epoch(ctx)
        );
    }

    // redeem when the vault reaches its maturity date
    public entry fun redeem<P>(wrapper: &mut SuiSystemState, global: &mut Global, pt: Coin<PT_TOKEN<P>>, ctx: &mut TxContext) {
        let vault_config = get_vault_config<P>(&mut global.pools);
        assert!(tx_context::epoch(ctx) > vault_config.maturity_epoch, E_VAULT_NOT_MATURED);
        assert!(coin::value<PT_TOKEN<P>>(&pt) >= MIN_PT_TO_REDEEM, E_MIN_THRESHOLD);

        let paidout_amount = coin::value<PT_TOKEN<P>>(&pt);

        prepare_withdrawal(wrapper, global, paidout_amount, ctx);

        // withdraw 
        withdraw_sui(&mut global.redemption_pool , paidout_amount, tx_context::sender(ctx), ctx);

        let vault_reserve = get_vault_reserve<P>(&mut global.pool_reserves);
        // burn PT tokens
        let burned_balance = balance::decrease_supply(&mut vault_reserve.pt_supply, coin::into_balance(pt));

        redeem_event(
            token_to_name<P>(),
            burned_balance,
            paidout_amount,
            tx_context::sender(ctx),
            tx_context::epoch(ctx)
        );
    }

    // exit the position before to the vault matures (disabled by default)
    public entry fun exit<P>(wrapper: &mut SuiSystemState, global: &mut Global, amm_global: &mut AMMGlobal, deposit_id: u64, pt: Coin<PT_TOKEN<P>>,yt: Coin<YT_TOKEN<P>>, ctx: &mut TxContext) {
        let vault_config = get_vault_config<P>(&mut global.pools);
        let vault_reserve = get_vault_reserve<P>(&mut global.pool_reserves);

        assert!(vault_config.enable_exit == true, E_EXIT_DISABLED);
        assert!(vault_config.maturity_epoch-COOLDOWN_EPOCH > tx_context::epoch(ctx), E_VAULT_MATURED);
        assert!( vector::length( &vault_config.deposit_items ) > deposit_id, E_INVALID_DEPOSIT_ID );
        
        let staked_sui = vector::swap_remove(&mut vault_config.deposit_items, deposit_id);
        let asset_object_id = object::id(&staked_sui);

        // PT needed calculates from the principal + accumurated rewards
        let needed_pt_amount = staking_pool::staked_sui_amount(&staked_sui)+apy_reader::earnings_from_staked_sui(wrapper, &staked_sui, tx_context::epoch(ctx));
        // YT covers of the remaining debt until the vault matures
        let pt_outstanding_debts = calculate_pt_debt_from_epoch(vault_config.vault_apy, tx_context::epoch(ctx), vault_config.maturity_epoch, needed_pt_amount);
        
        let amm_pool = amm::get_mut_pool<SUI, YT_TOKEN<P>>(amm_global, true);
        let (reserve_1, reserve_2, _) = amm::get_reserves_size<SUI, YT_TOKEN<P>>(amm_pool);
        let needed_yt_amount = amm::get_amount_out(
                pt_outstanding_debts,
                reserve_1,
                reserve_2
        );
        if (MIN_YT_FOR_EXIT > needed_yt_amount) needed_yt_amount = MIN_YT_FOR_EXIT;

        let input_pt_amount = coin::value<PT_TOKEN<P>>(&pt);
        let input_yt_amount = coin::value<YT_TOKEN<P>>(&yt);
        
        assert!( input_pt_amount >= needed_pt_amount , E_INSUFFICIENT_AMOUNT);
        assert!( input_yt_amount >= needed_yt_amount , E_INSUFFICIENT_AMOUNT);

        // burn PT
        if (input_pt_amount == needed_pt_amount) {
            balance::decrease_supply(&mut vault_reserve.pt_supply, coin::into_balance(pt));
        } else {
            balance::decrease_supply(&mut vault_reserve.pt_supply, coin::into_balance(coin::split(&mut pt, needed_pt_amount, ctx)));
            transfer::public_transfer(pt, tx_context::sender(ctx));
        };

        // burn YT
        if (input_yt_amount == needed_yt_amount) {
            balance::decrease_supply(&mut vault_reserve.yt_supply, coin::into_balance(yt));
        } else {
            balance::decrease_supply(&mut vault_reserve.yt_supply, coin::into_balance( coin::split(&mut yt, needed_yt_amount, ctx) ));
            transfer::public_transfer(yt, tx_context::sender(ctx));
        };

        // send out Staked SUI
        transfer::public_transfer(staked_sui, tx_context::sender(ctx)); 

        exit_event(
            token_to_name<P>(),
            deposit_id,
            asset_object_id,
            needed_pt_amount,
            needed_yt_amount,
            tx_context::sender(ctx),
            tx_context::epoch(ctx)
        );

    }

    public entry fun migrate<X,Y>(global: &mut Global, pt: Coin<PT_TOKEN<X>>, ctx: &mut TxContext) {
        check_vault_order<X,Y>(global);
        assert!(coin::value<PT_TOKEN<X>>(&pt) >= MIN_PT_TO_MIGRATE, E_MIN_THRESHOLD);

        // PT burning in the 1st reserve
        let (from_started_epoch, from_ended_epoch) = get_vault_epochs<X>(&global.pools);
        assert!(tx_context::epoch(ctx) >= from_started_epoch, E_VAULT_NOT_STARTED); 
        let from_vault_reserve = get_vault_reserve<X>(&mut global.pool_reserves);
        let amount_to_migrate = coin::value(&pt);
        balance::decrease_supply(&mut from_vault_reserve.pt_supply, coin::into_balance(pt));

        // minting PT on the 2nd reserve
        let to_vault_config = get_vault_config<Y>(&mut global.pools);
        let to_vault_reserve = get_vault_reserve<Y>(&mut global.pool_reserves);
        assert!(to_vault_config.maturity_epoch-COOLDOWN_EPOCH > tx_context::epoch(ctx), E_VAULT_MATURED);
        assert!(tx_context::epoch(ctx) >= to_vault_config.started_epoch, E_VAULT_NOT_STARTED);

        // Calculate extra PT to send out
        let debt_amount = calculate_pt_debt_from_epoch(to_vault_config.vault_apy, from_ended_epoch, to_vault_config.maturity_epoch, amount_to_migrate);
        let minted_pt_amount = amount_to_migrate+debt_amount;

        mint_pt<Y>(to_vault_reserve, minted_pt_amount, ctx);

        // emit event
        migrate_event(
            token_to_name<X>(),
            amount_to_migrate,
            token_to_name<Y>(),
            minted_pt_amount,
            tx_context::sender(ctx),
            tx_context::epoch(ctx)
        );
    }

    public fun get_vault_config<P>(table: &mut Table<String, PoolConfig>): &mut PoolConfig  {
        let vault_name = token_to_name<P>();
        let has_registered = table::contains(table, vault_name);
        assert!(has_registered, E_NOT_REGISTERED);

        table::borrow_mut<String, PoolConfig>(table, vault_name)
    }

    public fun get_vault_reserve<P>(vaults: &mut Bag): &mut PoolReserve<P> {
        let vault_name = token_to_name<P>();
        let has_registered = bag::contains_with_type<String, PoolReserve<P>>(vaults, vault_name);
        assert!(has_registered, E_NOT_REGISTERED);

        bag::borrow_mut<String, PoolReserve<P>>(vaults, vault_name)
    }

    public fun get_vault_epochs<P>(table: &Table<String, PoolConfig>) : (u64, u64) {
        let vault_name = token_to_name<P>();
        let has_registered = table::contains(table, vault_name);
        assert!(has_registered, E_NOT_REGISTERED);
        let pool_config = table::borrow(table, vault_name );
        (pool_config.started_epoch, pool_config.maturity_epoch)
    }

    // ======== Only Governance =========

    // create new Staked SUI vault 
    public entry fun new_vault<P>(global: &mut Global, amm_global: &mut AMMGlobal, _manager_cap: &mut ManagerCap, started_epoch: u64, maturity_epoch: u64, initial_apy: u64, initial_liquidity: Coin<SUI>, ctx: &mut TxContext) {
        assert!( maturity_epoch > tx_context::epoch(ctx) , E_INVALID_MATURITY);
        assert!(started_epoch >= tx_context::epoch(ctx) , E_INVALID_STARTED);
        assert!(maturity_epoch-started_epoch >= MIN_VAULT_SPAN, E_TOO_SHORT);

        // verify if the vault has been created
        let vault_name = token_to_name<P>();
        let has_registered = bag::contains_with_type<String, PoolReserve<P>>(&global.pool_reserves, vault_name);
        assert!(!has_registered, E_DUPLICATED_ENTRY);

        // the start epoch must be within the previous vault's start and maturity epochs
        if (vector::length(&global.pool_list) > 0) {
            let pool_name = *vector::borrow( &global.pool_list, vector::length(&global.pool_list)-1);
            let pool_config = table::borrow(&global.pools, pool_name);
            assert!((started_epoch > pool_config.started_epoch &&  pool_config.maturity_epoch > started_epoch) , E_INVALID_STARTED);
        };

        let pool_config = PoolConfig {
            started_epoch,
            maturity_epoch,
            vault_apy: initial_apy, 
            deposit_items: vector::empty<StakedSui>(),
            enable_exit : false,
            enable_mint: true
        };

        let pool_reserve = PoolReserve {
            pt_supply: balance::create_supply(PT_TOKEN<P> {}),
            yt_supply: balance::create_supply(YT_TOKEN<P> {})
        };

        // setup YT supply
        let minted_yt = balance::increase_supply(&mut pool_reserve.yt_supply, YT_TOTAL_SUPPLY);

        // setup AMM for YT
        let is_order = true;
        amm::register_pool<SUI, YT_TOKEN<P>>(amm_global, is_order);
        let amm_pool = amm::get_mut_pool<SUI, YT_TOKEN<P>>(amm_global, is_order);

        let (lp, _) = amm::add_liquidity_non_entry<SUI, YT_TOKEN<P>>( amm_pool, initial_liquidity, 1, coin::from_balance(minted_yt, ctx), 1, is_order, ctx);
        transfer::public_transfer(lp ,tx_context::sender(ctx));

        bag::add(&mut global.pool_reserves, vault_name, pool_reserve);
        table::add(&mut global.pools, vault_name, pool_config);
        vector::push_back<String>(&mut global.pool_list, vault_name);

        // emit event
        new_vault_event(
            object::id(global),
            vault_name,
            tx_context::epoch(ctx),
            started_epoch,
            maturity_epoch,
            initial_apy
        )
    }

    // add support staking pool
    public entry fun attach_pool(global: &mut Global, _manager_cap: &mut ManagerCap, pool_address:address, pool_id: ID) {
        assert!(!vector::contains(&global.staking_pools, &pool_address), E_DUPLICATED_ENTRY);
        vector::push_back<address>(&mut global.staking_pools, pool_address);
        vector::push_back<ID>(&mut global.staking_pool_ids, pool_id);
    }

    // remove support staking pool
    public entry fun detach_pool(global: &mut Global, _manager_cap: &mut ManagerCap, pool_address: address) {
        let (contained, index) = vector::index_of<address>(&global.staking_pools, &pool_address);
        assert!(contained, E_NOT_FOUND);
        vector::remove<address>(&mut global.staking_pools, index);
        vector::remove<ID>(&mut global.staking_pool_ids, index);
    }

    public entry fun enable_exit<P>(global: &mut Global, _manager_cap: &mut ManagerCap) {
        let vault_config = get_vault_config<P>( &mut global.pools);
        vault_config.enable_exit = true;
    }

    public entry fun disable_exit<P>(global: &mut Global, _manager_cap: &mut ManagerCap) {
        let vault_config = get_vault_config<P>( &mut global.pools);
        vault_config.enable_exit = false;
    }

    public entry fun enable_mint<P>(global: &mut Global, _manager_cap: &mut ManagerCap) {
        let vault_config = get_vault_config<P>( &mut global.pools);
        vault_config.enable_mint = true;
    }

    public entry fun disable_mint<P>(global: &mut Global, _manager_cap: &mut ManagerCap) {
        let vault_config = get_vault_config<P>( &mut global.pools);
        vault_config.enable_mint = false;
    }

    // ======== Internal Functions =========

    // when there're 2 fixed-term vaults active simultaneously
    fun check_not_paused(global: &Global, current_epoch: u64) {
        assert!( vector::length(&global.pool_list) > 1 , E_PAUSED_STATE);
        let total = vector::length(&global.pool_list);
        let recent_pool_name = *vector::borrow( &global.pool_list, total-1);
        let recent_pool_config = table::borrow(&global.pools, recent_pool_name);
        assert!((recent_pool_config.maturity_epoch >= current_epoch) , E_PAUSED_STATE);

        let ref_pool_name = *vector::borrow( &global.pool_list, total-2);
        let ref_pool_config = table::borrow(&global.pools, ref_pool_name);
        assert!((ref_pool_config.maturity_epoch >= current_epoch) , E_PAUSED_STATE);
    }

    fun check_vault_order<X,Y>(global: &Global) {
        let from_pool_name = token_to_name<X>();
        let to_pool_name = token_to_name<Y>();
        let (from_contained, from_id) = vector::index_of<String>(&global.pool_list, &from_pool_name);
        assert!(from_contained,E_NOT_REGISTERED);
        let (to_contained, to_id) = vector::index_of<String>(&global.pool_list, &to_pool_name);
        assert!(to_contained,E_NOT_REGISTERED);
        assert!( to_id > from_id ,E_VAULT_NOT_ORDER);
    }

    // initiates the withdrawal by unstaking locked Staked SUI objects and retaining SUI tokens in the redemption pool
    fun prepare_withdrawal(wrapper: &mut SuiSystemState, global: &mut Global, paidout_amount: u64, ctx: &mut TxContext) {
        
        // ignore if there are sufficient SUI to pay out 
        if (paidout_amount > balance::value(&global.redemption_pool.pending_withdrawal)) {
            // extract all asset IDs to be withdrawn
            let pending_withdrawal = balance::value(&global.redemption_pool.pending_withdrawal);
            let (pool_list, asset_ids) = locate_withdrawable_asset(wrapper, &global.pool_list, &mut global.pools, paidout_amount, pending_withdrawal, tx_context::epoch(ctx));

            // unstake assets
            let sui_balance = unstake_staked_sui(wrapper, &mut global.pools, pool_list, asset_ids, ctx);
            balance::join<SUI>(&mut global.redemption_pool.pending_withdrawal, sui_balance);
        };
    }

    fun locate_withdrawable_asset(wrapper: &mut SuiSystemState, pool_list: &vector<String>, pools: &mut Table<String, PoolConfig> , paidout_amount: u64, pending_withdrawal: u64, epoch: u64): (vector<String>,vector<u64>)  {

        // debug::print(pool_list);

        let pool_count = 0;
        let asset_pools = vector::empty();
        let asset_ids = vector::empty();
        let amount_to_unwrap = paidout_amount-pending_withdrawal;
        
        while (pool_count < vector::length(pool_list)) { 
            let pool_name = *vector::borrow(pool_list, pool_count);
            let pool = table::borrow_mut(pools, pool_name); 
            let item_count = 0;
            while (item_count < vector::length(&pool.deposit_items)) {
                let staked_sui = vector::borrow(&pool.deposit_items, item_count);
                let amount_with_rewards = staking_pool::staked_sui_amount(staked_sui)+apy_reader::earnings_from_staked_sui(wrapper, staked_sui, epoch);
                
                vector::push_back<String>(&mut asset_pools, pool_name);
                vector::push_back<u64>(&mut asset_ids, item_count);

                amount_to_unwrap =
                    if (paidout_amount >= amount_with_rewards)
                        paidout_amount - amount_with_rewards
                    else 0;

                item_count = item_count+1;
                if (amount_to_unwrap == 0) break
            };

            pool_count = pool_count + 1;
            if (amount_to_unwrap == 0) break
        };

        (asset_pools,asset_ids)
    }

    fun unstake_staked_sui(wrapper: &mut SuiSystemState, pools: &mut Table<String, PoolConfig>, asset_pools:vector<String>, asset_ids: vector<u64>, ctx: &mut TxContext): Balance<SUI> {

        let balance_sui = balance::zero();

        while (vector::length<u64>(&asset_ids) > 0) {
            let pool_name = vector::pop_back(&mut asset_pools);
            let asset_id = vector::pop_back(&mut asset_ids);
            
            let pool = table::borrow_mut(pools, pool_name); 
            let staked_sui = vector::swap_remove(&mut pool.deposit_items, asset_id);
            let balance_each = sui_system::request_withdraw_stake_non_entry(wrapper, staked_sui, ctx);
            balance::join<SUI>(&mut balance_sui, balance_each);
        };

        balance_sui
    }

    fun receive_staked_sui(vault_config: &mut PoolConfig, staked_sui: StakedSui) {
        vector::push_back<StakedSui>(&mut vault_config.deposit_items, staked_sui);
        if (vector::length(&vault_config.deposit_items) > 1) sort_items(&mut vault_config.deposit_items);
    }
    
    fun mint_pt<P>(vault_reserve: &mut PoolReserve<P>, amount: u64, ctx: &mut TxContext) {
        let minted_balance = balance::increase_supply(&mut vault_reserve.pt_supply, amount);
        transfer::public_transfer(coin::from_balance(minted_balance, ctx), tx_context::sender(ctx));
    }

    fun withdraw_sui(redemption_pool: &mut RedemptionPool, amount: u64, recipient: address , ctx: &mut TxContext) {
        assert!( balance::value(&redemption_pool.pending_withdrawal) >= amount, E_INVALID_AMOUNT);

        let payout_balance = balance::split(&mut redemption_pool.pending_withdrawal, amount);
        transfer::public_transfer(coin::from_balance(payout_balance, ctx), recipient);
    }

    // ======== Test-related Functions =========

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

}