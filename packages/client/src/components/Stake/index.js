

import { LegatoContext } from "@/hooks/useLegato"
import { ModalContext } from "@/hooks/useModal"
import Link from 'next/link'
import { CheckIcon, ChevronUpDownIcon, ChevronDownIcon, ArrowRightIcon } from "@heroicons/react/20/solid"
import { useContext } from "react"
import { MODAL } from "@/hooks/useModal"
import SuiToStakedSui from "./SuiToStakedSui"
import StakedSuiToPT from "./StakedSuiToPT"

const Stake = ({
    summary,
    validators,
    suiPrice,
    avgApy
}) => {

    const { openModal } = useContext(ModalContext)
    const { currentMarket, market } = useContext(LegatoContext)

    const onMarketSelect = () => {
        openModal(MODAL.MARKET, {
            suiSystemApy: avgApy
        })
    }

    return (
        <div>
            <div className="max-w-xl ml-auto mr-auto">
                <div class="wrapper pt-10">
                    <div class="rounded-3xl p-px bg-gradient-to-b  from-blue-800 to-purple-800 ">
                        <div class="rounded-[calc(1.5rem-1px)] p-10 bg-gray-900">

                            {/* SELECT MARKET */}

                            <div class="flex gap-10 items-center ">
                                <p class="text-gray-300">
                                    Select Market
                                </p>
                                <div onClick={onMarketSelect} class="flex gap-4 items-center flex-1 p-2 hover:cursor-pointer rounded-md">
                                    <div class="relative">
                                        <img class="h-12 w-12 rounded-full" src={market.img} alt="" />
                                        {market.isPT && <img src="/pt-badge.png" class="bottom-0 right-7 absolute  w-7 h-4  " />}
                                    </div>
                                    <div>
                                        <h3 class="text-2xl font-medium text-white">{market.from}</h3>
                                        <span class="text-sm tracking-wide text-gray-400">{market.to}</span>
                                    </div>
                                    <div class="ml-auto ">
                                        <ChevronUpDownIcon className="h-6 w-6 text-gray-300" />
                                    </div>
                                </div>
                            </div>

                            {/* ACTION PANEL */}

                            <div className="mt-6">
                                {currentMarket === "SUI_TO_STAKED_SUI" && (
                                    <SuiToStakedSui
                                        validators={validators}
                                        avgApy={avgApy}
                                        suiPrice={suiPrice}
                                    />
                                )}

                                {currentMarket === "STAKED_SUI_TO_PT" && (
                                    <StakedSuiToPT />
                                )}
                            </div>
                        </div>
                    </div>
                </div>
            </div>


            {/* DISCLAIMER */}
            <div className="max-w-lg ml-auto mr-auto">
                <p class="text-neutral-400 text-sm p-5 text-center">
                    {`The Legato version you're using is in its early and unaudited stage. It's still in development and may have undiscovered issues.`}
                </p>
                {/* <p class="text-neutral-400 underline text-sm p-5 pt-0 text-center">
                    <Link href="/portfolio">
                        Wrap your Testnet SUI to Staked SUI object{` >>`}
                    </Link>
                </p> */}
            </div>
        </div>
    )
}

export default Stake