module legato::vault {
    
    // use std::option;
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin };
    use sui::balance::{ Self, Supply };
    use sui::object::{Self, UID, ID };
    use sui::transfer; 
    use sui::event;
    // use sui::dynamic_object_field as ofield;
    use legato::epoch_time_lock::{ Self, EpochTimeLock};
    use legato::oracle::{Self, Feed};
    use legato::staked_sui::{ Self, StakedSui }; // clones of staking_pool.move
    
    const YT_TOTAL_SUPPLY: u64 = 1000000000;

    const FEED_DECIMAL_PLACE: u64 = 3;

    const EZeroAmount: u64 = 0;
    const EVaultExpired: u64 = 1;
    const EInvalidStakeActivationEpoch: u64 = 2;
    const EInsufficientAmount: u64 = 3;
    const EInvalidDepositID: u64 = 4;

    struct ManagerCap has key {
        id: UID,
    }

    struct PT has drop {}
    struct YT has drop {}

    struct TOKEN<phantom T> has drop {}
 
    struct Reserve has key {
        id: UID,
        deposits: Table<u64, StakedSui>,
        deposit_count: u64,
        balance: u64,
        pt: Supply<TOKEN<PT>>,
        yt: Supply<TOKEN<YT>>,
        feed : Feed,
        locked_until_epoch: EpochTimeLock
    }

    struct LockEvent has copy, drop {
        reserve_id: ID,
        deposit_amount: u128,
        deposit_id: u64,
        pt_amount: u64,
        owner: address
    }

    struct UnlockEvent has copy, drop {
        reserve_id: ID,
        burned_amount: u64,
        deposit_id: u64,
        owner: address
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            ManagerCap {id: object::new(ctx)},
            tx_context::sender(ctx)
        );
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init( ctx);
    }

    // create new vault
    public entry fun new_vault(
        _manager_cap: &mut ManagerCap,
        lockForEpoch : u64,
        ctx: &mut TxContext
    ) {

        let deposits = table::new(ctx);

        // setup PT
        let pt = balance::create_supply(TOKEN<PT> {});
        // setup YT
        let yt = balance::create_supply(TOKEN<YT> {});

        // // give 1 mil. of YT tokens to the sender
        // // coin::mint_and_transfer<YT>(&mut yt_treasury_cap, YT_TOTAL_SUPPLY, tx_context::sender(ctx), ctx);

        let reserve = Reserve {
            id: object::new(ctx),
            deposits,
            deposit_count: 0,
            pt,
            yt,
            balance: 0,
            feed : oracle::new_feed(FEED_DECIMAL_PLACE,ctx), // ex. 4.123%
            locked_until_epoch : epoch_time_lock::new(tx_context::epoch(ctx) + lockForEpoch, ctx)
        };

        transfer::share_object(reserve);
    }

    // lock tokens to receive PT
    public entry fun lock(
        reserve: &mut Reserve,
        input: StakedSui,
        ctx: &mut TxContext
    ) {

        let amount = staked_sui::staked_sui_amount(&input);
        let until_epoch = epoch_time_lock::epoch(&reserve.locked_until_epoch);

        assert!(amount >= 0, EZeroAmount);
        assert!(until_epoch > tx_context::epoch(ctx), EVaultExpired );
        assert!(until_epoch > staked_sui::stake_activation_epoch(&input), EInvalidStakeActivationEpoch );

        let user = tx_context::sender(ctx);

        // deposit Stake Sui objects into the table

        table::add(
            &mut reserve.deposits,
            reserve.deposit_count,
            input
        );

        reserve.balance = reserve.balance + amount;
        reserve.deposit_count = reserve.deposit_count + 1;

        // calculate epoch remaining until the vault matures
        let diff = until_epoch-tx_context::epoch(ctx);
        let (val, _ ) = oracle::get_value(&reserve.feed);

        let (
            diff,
            val,
            amount
        ) = (
            (diff as u128),
            (val as u128),
            (amount as u128)
        );

        let add_pt_amount = diff*val*amount / 36500000;
        add_pt_amount = add_pt_amount+amount;
        let add_pt_amount = (add_pt_amount as u64);

        let minted_balance = balance::increase_supply(&mut reserve.pt,add_pt_amount);

        transfer::public_transfer(coin::from_balance(minted_balance, ctx), user);

        event::emit(LockEvent {
            reserve_id: object::id(reserve),
            deposit_amount: amount,
            deposit_id : reserve.deposit_count - 1,
            pt_amount: add_pt_amount,
            owner : tx_context::sender(ctx)
        });
    }

    // unlock Staked SUI object, must providing deposit ID
    public entry fun unlock_after_mature(
        reserve: &mut Reserve,
        deposit_id: u64,
        pt: &mut Coin<TOKEN<PT>>,
        ctx: &mut TxContext
    ) {

        assert!(table::contains(&mut reserve.deposits, deposit_id), EInvalidDepositID);
 
        let deposit_item = table::remove(&mut reserve.deposits, deposit_id);
        let amount = staked_sui::staked_sui_amount(&deposit_item);

        assert!(coin::value(pt) >= amount, EInsufficientAmount);

        let deducted = coin::split(pt, amount, ctx);

        epoch_time_lock::destroy(reserve.locked_until_epoch, ctx);
        let burned_balance = balance::decrease_supply(&mut reserve.pt, coin::into_balance(deducted));

        let user = tx_context::sender(ctx);

        transfer::public_transfer(deposit_item, user);

        reserve.balance = reserve.balance - amount;
        
        event::emit(UnlockEvent {
            reserve_id: object::id(reserve),
            burned_amount : burned_balance,
            deposit_id,
            owner : tx_context::sender(ctx)
        });
    }

    // TODO: unlock before mature using YT

    public fun total_yt_supply(reserve: &Reserve): u64 {
        balance::supply_value(&reserve.yt)
    }

    public fun total_pt_supply(reserve: &Reserve): u64 {
        balance::supply_value(&reserve.pt)
    }

    public entry fun balance(reserve: &Reserve): u64 {
        reserve.balance
    }

    public entry fun feed_value(reserve: &Reserve) : (u64) {
        let (val, _ ) = oracle::get_value(&reserve.feed);
        val
    }

    public entry fun feed_decimal(reserve: &Reserve) : (u64) {
        let (_, dec ) = oracle::get_value(&reserve.feed);
        dec
    }

    // transfer manager cap to someone else
    public entry fun transfer_manager_cap(
        _manager_cap: &ManagerCap,
        recipient: address,
        ctx: &mut TxContext
    ) {
        transfer::transfer(ManagerCap {id: object::new(ctx)}, recipient);
    }

    // update APR value
    public entry fun update_feed_value(
        _manager_cap: &ManagerCap,
        reserve: &mut Reserve,
        value: u64,
        ctx: &mut TxContext
    ) {
        oracle::update(&mut reserve.feed, value, ctx)
    }

}