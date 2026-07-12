import { expect } from "chai";
import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";

import { mint as MintInfo } from "../../ts-sdk/mint";
import { LendingBaseSetup } from "../../test-utils/typescript/lending/setup";
import { FluidLiquidityResolver } from "../../test-utils/typescript/liquidity/resolver";
import { LendingResolver } from "../../test-utils/typescript/lending/resolver";

const UNIT = new BN(1_000_000);
const DEPOSIT_PER_HOLDER = new BN(1_000).mul(UNIT);

// Alice + Bob deposit 2,000 total.
// 400 reward over one year = 20% annualized reward rate.
const REWARD_AMOUNT = new BN(400).mul(UNIT);

const REWARD_DURATION_SECONDS = 365 * 24 * 60 * 60;
const REWARD_START_DELAY_SECONDS = 2;

describe("Lending reward-gap two-holder PoC", () => {
  let setup: LendingBaseSetup;
  let liquidityResolver: FluidLiquidityResolver;
  let lendingResolver: LendingResolver;
  let underlyingMint: PublicKey;

  beforeEach(async () => {
    process.env.TEST_MODE_JEST = "true";

    setup = new LendingBaseSetup();
    await setup.setup();

    underlyingMint = MintInfo.getMint(setup.underlying);

    liquidityResolver = new FluidLiquidityResolver(
      setup.admin,
      setup.liquidity,
      setup.client
    );

    lendingResolver = new LendingResolver(
      setup.admin,
      setup.lending,
      liquidityResolver,
      setup.client,
      setup.lrrm
    );
  });

  afterEach(async () => {
    setup.logComputeBudget();
  });

  it(
    "PoC: unfunded rewards let the first redeemer consume principal backing and block the second holder",
    async () => {
      /*
       * Step 1:
       * Record Alice and Bob balances before either holder deposits.
       */
      const aliceUnderlyingBefore = await setup.balanceOf(
        setup.alice.publicKey,
        underlyingMint
      );

      const bobUnderlyingBefore = await setup.balanceOf(
        setup.bob.publicKey,
        underlyingMint
      );

      /*
       * Step 2:
       * Alice and Bob deposit equal principal amounts.
       */
      await setup.depositToLending(
        setup.underlying,
        DEPOSIT_PER_HOLDER,
        setup.alice
      );

      await setup.depositToLending(
        setup.underlying,
        DEPOSIT_PER_HOLDER,
        setup.bob
      );

      const aliceShares = await setup.balanceOf(
        setup.alice.publicKey,
        setup.underlyingFToken
      );

      const bobShares = await setup.balanceOf(
        setup.bob.publicKey,
        setup.underlyingFToken
      );

      expect(aliceShares.gt(new BN(0))).to.be.true;
      expect(bobShares.gt(new BN(0))).to.be.true;

      /*
       * Step 3:
       * Configure 400 underlying units of rewards over one year.
       *
       * Critically, no rebalance or backing transfer is performed here.
       */
      const rewardStartTime = new BN(
        parseInt(setup.timestamp(), 10) +
          REWARD_START_DELAY_SECONDS
      );

      await setup.setRewardsRateWithAmount(
        setup.underlying,
        REWARD_AMOUNT,
        new BN(REWARD_DURATION_SECONDS),
        rewardStartTime,
        new BN(1)
      );

      /*
       * Step 4:
       * Advance past the entire reward period, then crystallize the
       * reward-backed token exchange price.
       */
      setup.warp(
        REWARD_DURATION_SECONDS +
          REWARD_START_DELAY_SECONDS +
          1
      );

      await setup.updateRate(setup.underlying);

      /*
       * Step 5:
       * Show that accounting claims now exceed actual Liquidity backing.
       */
      const claimsBeforeExit =
        await lendingResolver.totalAssets(setup.underlying);

      const internalBeforeExit =
        await lendingResolver.getFTokenInternalData(
          setup.underlying
        );

      const backingBeforeExit =
        internalBeforeExit.liquidityBalance;

      const gapBeforeExit =
        claimsBeforeExit.sub(backingBeforeExit);

      expect(gapBeforeExit.gt(new BN(0))).to.be.true;

      // The gap should be approximately the configured reward amount.
      expect(
        gapBeforeExit.gte(
          REWARD_AMOUNT.mul(new BN(95)).div(new BN(100))
        )
      ).to.be.true;

      /*
       * Step 6:
       * Alice exits first and redeems every share.
       */
      await setup.redeemFromLending(
        setup.underlying,
        aliceShares,
        setup.alice
      );

      const aliceUnderlyingAfter = await setup.balanceOf(
        setup.alice.publicKey,
        underlyingMint
      );

      const aliceNetProfit =
        aliceUnderlyingAfter.sub(aliceUnderlyingBefore);

      /*
       * Alice deposited principal and exits with more underlying than
       * she originally held, despite no reward rebalance having occurred.
       */
      expect(aliceNetProfit.gt(new BN(0))).to.be.true;

      const aliceSharesAfter = await setup.balanceOf(
        setup.alice.publicKey,
        setup.underlyingFToken
      );

      expect(aliceSharesAfter.eq(new BN(0))).to.be.true;

      /*
       * Step 7:
       * The original absolute deficit remains attached to Bob's position.
       */
      const claimsAfterAlice =
        await lendingResolver.totalAssets(setup.underlying);

      const internalAfterAlice =
        await lendingResolver.getFTokenInternalData(
          setup.underlying
        );

      const backingAfterAlice =
        internalAfterAlice.liquidityBalance;

      const gapAfterAlice =
        claimsAfterAlice.sub(backingAfterAlice);

      expect(gapAfterAlice.gt(new BN(0))).to.be.true;

      // Allow minor fixed-point rounding while showing the deficit persists.
      expect(
        gapAfterAlice.gte(
          gapBeforeExit.mul(new BN(99)).div(new BN(100))
        )
      ).to.be.true;

      expect(claimsAfterAlice.gt(backingAfterAlice)).to.be.true;

      /*
       * Step 8:
       * Bob now attempts to redeem every share.
       *
       * This must fail because his accounting claim exceeds the remaining
       * Liquidity backing assigned to the Lending protocol position.
       */
      const bobSharesBeforeFailedRedeem =
        await setup.balanceOf(
          setup.bob.publicKey,
          setup.underlyingFToken
        );

      let bobFullRedeemFailed = false;
      let bobFailureMessage = "";

      try {
        await setup.redeemFromLending(
          setup.underlying,
          bobSharesBeforeFailedRedeem,
          setup.bob
        );
      } catch (error) {
        bobFullRedeemFailed = true;
        bobFailureMessage =
          error instanceof Error
            ? error.message
            : String(error);
      }

      expect(bobFullRedeemFailed).to.be.true;

      /*
       * Failed Solana transactions are atomic, so Bob's shares must remain.
       */
      const bobSharesAfterFailedRedeem =
        await setup.balanceOf(
          setup.bob.publicKey,
          setup.underlyingFToken
        );

      expect(
        bobSharesAfterFailedRedeem.eq(
          bobSharesBeforeFailedRedeem
        )
      ).to.be.true;

      /*
       * Step 9:
       * Fund the privileged rebalancer locally with the exact deficit plus
       * a tiny margin, then perform the required rescue rebalance.
       */
      await setup.mint(
        underlyingMint,
        setup.admin.publicKey,
        gapAfterAlice.add(new BN(1_000))
      );

      await setup.rebalance(
        setup.underlying,
        setup.admin
      );

      const claimsAfterRebalance =
        await lendingResolver.totalAssets(setup.underlying);

      const internalAfterRebalance =
        await lendingResolver.getFTokenInternalData(
          setup.underlying
        );

      const backingAfterRebalance =
        internalAfterRebalance.liquidityBalance;

      /*
       * Rebalance should restore sufficient backing for Bob.
       */
      expect(
        backingAfterRebalance.gte(
          claimsAfterRebalance.sub(new BN(10_000))
        )
      ).to.be.true;

      /*
       * Step 10:
       * The exact Bob redemption that failed before the privileged top-up
       * now succeeds.
       */
      const bobSharesForFinalRedeem =
        await setup.balanceOf(
          setup.bob.publicKey,
          setup.underlyingFToken
        );

      await setup.redeemFromLending(
        setup.underlying,
        bobSharesForFinalRedeem,
        setup.bob
      );

      const bobSharesFinal = await setup.balanceOf(
        setup.bob.publicKey,
        setup.underlyingFToken
      );

      const bobUnderlyingAfter = await setup.balanceOf(
        setup.bob.publicKey,
        underlyingMint
      );

      expect(bobSharesFinal.eq(new BN(0))).to.be.true;
      expect(bobUnderlyingAfter.gt(bobUnderlyingBefore)).to.be.true;

      console.log(
        "TRFFNSEC_REWARD_GAP_TWO_HOLDER_POC",
        JSON.stringify(
          {
            depositPerHolder:
              DEPOSIT_PER_HOLDER.toString(),

            configuredReward:
              REWARD_AMOUNT.toString(),

            claimsBeforeExit:
              claimsBeforeExit.toString(),

            backingBeforeExit:
              backingBeforeExit.toString(),

            gapBeforeExit:
              gapBeforeExit.toString(),

            aliceNetProfit:
              aliceNetProfit.toString(),

            claimsAfterAlice:
              claimsAfterAlice.toString(),

            backingAfterAlice:
              backingAfterAlice.toString(),

            gapAfterAlice:
              gapAfterAlice.toString(),

            bobFullRedeemFailed,

            bobFailureMessage,

            claimsAfterRebalance:
              claimsAfterRebalance.toString(),

            backingAfterRebalance:
              backingAfterRebalance.toString(),

            bobFinalShares:
              bobSharesFinal.toString(),
          },
          null,
          2
        )
      );
    },
    180_000
  );
});
