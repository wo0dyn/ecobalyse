module Data.Formula exposing (..)

import Data.Impact as Impact exposing (Impacts)
import Data.Process as Process exposing (Process)
import Data.Transport as Transport exposing (Transport)
import Data.Unit as Unit
import Energy exposing (Energy)
import Mass exposing (Mass)
import Quantity



-- Waste


{-| Compute source material mass needed and waste generated by the operation.
-}
genericWaste : Mass -> Mass -> { waste : Mass, mass : Mass }
genericWaste processWaste baseMass =
    let
        waste =
            baseMass
                |> Quantity.multiplyBy (Mass.inKilograms processWaste)
    in
    { waste = waste, mass = baseMass |> Quantity.plus waste }


{-| Compute source material mass needed and waste generated by the operation from
ratioed pristine/recycled material processes data.
-}
materialRecycledWaste :
    { pristineWaste : Mass
    , recycledWaste : Mass
    , recycledRatio : Unit.Ratio
    }
    -> Mass
    -> { waste : Mass, mass : Mass }
materialRecycledWaste { pristineWaste, recycledWaste, recycledRatio } baseMass =
    let
        ( recycledMass, pristineMass ) =
            ( baseMass |> Quantity.multiplyBy (Unit.ratioToFloat recycledRatio)
            , baseMass |> Quantity.multiplyBy (1 - Unit.ratioToFloat recycledRatio)
            )

        ( ratioedRecycledWaste, ratioedPristineWaste ) =
            ( recycledMass |> Quantity.multiplyBy (Mass.inKilograms recycledWaste)
            , pristineMass |> Quantity.multiplyBy (Mass.inKilograms pristineWaste)
            )

        waste =
            Quantity.plus ratioedRecycledWaste ratioedPristineWaste
    in
    { waste = waste
    , mass = Quantity.sum [ pristineMass, recycledMass, waste ]
    }


{-| Compute source material mass needed and waste generated by the operation, according to
material & product waste data.
-}
makingWaste :
    { processWaste : Mass
    , pcrWaste : Unit.Ratio
    }
    -> Mass
    -> { waste : Mass, mass : Mass }
makingWaste { processWaste, pcrWaste } baseMass =
    let
        mass =
            -- (product weight + textile waste for confection) / (1 - PCR product waste rate)
            Mass.kilograms <|
                (Mass.inKilograms baseMass + (Mass.inKilograms baseMass * Mass.inKilograms processWaste))
                    / (1 - Unit.ratioToFloat pcrWaste)
    in
    { waste = Quantity.minus baseMass mass, mass = mass }



-- Impacts


materialAndSpinningImpacts :
    Impacts
    -> ( Process, Process ) -- Inbound: Material processes (recycled, non-recycled)
    -> Unit.Ratio -- Ratio of recycled material (bewteen 0 and 1)
    -> Mass
    -> Impacts
materialAndSpinningImpacts impacts ( recycledProcess, nonRecycledProcess ) ratio mass =
    impacts
        |> Impact.mapImpacts
            (\trigram _ ->
                mass
                    |> Unit.ratioedForKg
                        ( Process.getImpact trigram recycledProcess
                        , Process.getImpact trigram nonRecycledProcess
                        )
                        ratio
            )


pureMaterialAndSpinningImpacts : Impacts -> Process -> Mass -> Impacts
pureMaterialAndSpinningImpacts impacts process mass =
    impacts
        |> Impact.mapImpacts
            (\trigram _ ->
                mass
                    |> Unit.forKg (Process.getImpact trigram process)
            )


dyeingImpacts :
    Impacts
    -> ( Process, Process ) -- Inbound: Dyeing processes (low, high)
    -> Unit.Ratio -- Low/high dyeing process ratio
    -> Process -- Outbound: country heat impact
    -> Process -- Outbound: country electricity impact
    -> Mass
    -> { heat : Energy, kwh : Energy, impacts : Impacts }
dyeingImpacts impacts ( dyeingLowProcess, dyeingHighProcess ) (Unit.Ratio highDyeingWeighting) heatProcess elecProcess baseMass =
    let
        lowDyeingWeighting =
            1 - highDyeingWeighting

        ( lowDyeingMass, highDyeingMass ) =
            ( baseMass |> Quantity.multiplyBy lowDyeingWeighting
            , baseMass |> Quantity.multiplyBy highDyeingWeighting
            )

        heatMJ =
            Mass.inKilograms baseMass
                * ((highDyeingWeighting * Energy.inMegajoules dyeingHighProcess.heat)
                    + (lowDyeingWeighting * Energy.inMegajoules dyeingLowProcess.heat)
                  )
                |> Energy.megajoules

        electricity =
            Mass.inKilograms baseMass
                * ((highDyeingWeighting * Energy.inMegajoules dyeingHighProcess.elec)
                    + (lowDyeingWeighting * Energy.inMegajoules dyeingLowProcess.elec)
                  )
                |> Energy.megajoules
    in
    { heat = heatMJ
    , kwh = electricity
    , impacts =
        impacts
            |> Impact.mapImpacts
                (\trigram _ ->
                    let
                        dyeingImpact_ =
                            Quantity.sum
                                [ Unit.forKg (Process.getImpact trigram dyeingLowProcess) lowDyeingMass
                                , Unit.forKg (Process.getImpact trigram dyeingHighProcess) highDyeingMass
                                ]

                        heatImpact =
                            heatMJ |> Unit.forMJ (Process.getImpact trigram heatProcess)

                        elecImpact =
                            electricity |> Unit.forKWh (Process.getImpact trigram elecProcess)
                    in
                    Quantity.sum [ dyeingImpact_, heatImpact, elecImpact ]
                )
    }


makingImpacts :
    Impacts
    -> { makingProcess : Process, countryElecProcess : Process }
    -> Mass
    -> { kwh : Energy, impacts : Impacts }
makingImpacts impacts { makingProcess, countryElecProcess } _ =
    -- Note: In Base Impacts, impacts are precomputed per "item", and are
    --       therefore not mass-dependent.
    { kwh = makingProcess.elec
    , impacts =
        impacts
            |> Impact.mapImpacts
                (\trigram _ ->
                    makingProcess.elec
                        |> Unit.forKWh (Process.getImpact trigram countryElecProcess)
                )
    }


knittingImpacts :
    Impacts
    -> { elec : Energy, countryElecProcess : Process }
    -> Mass
    -> { kwh : Energy, impacts : Impacts }
knittingImpacts impacts { elec, countryElecProcess } baseMass =
    let
        electricityKWh =
            Energy.kilowattHours
                (Mass.inKilograms baseMass * Energy.inKilowattHours elec)
    in
    { kwh = electricityKWh
    , impacts =
        impacts
            |> Impact.mapImpacts
                (\trigram _ ->
                    electricityKWh
                        |> Unit.forKWh (Process.getImpact trigram countryElecProcess)
                )
    }


weavingImpacts :
    Impacts
    ->
        { elecPppm : Float
        , countryElecProcess : Process
        , ppm : Int
        , grammage : Int
        }
    -> Mass
    -> { kwh : Energy, impacts : Impacts }
weavingImpacts impacts { elecPppm, countryElecProcess, ppm, grammage } baseMass =
    let
        electricityKWh =
            (Mass.inKilograms baseMass * 1000 * toFloat ppm / toFloat grammage)
                * elecPppm
                |> Energy.kilowattHours
    in
    { kwh = electricityKWh
    , impacts =
        impacts
            |> Impact.mapImpacts
                (\trigram _ ->
                    electricityKWh
                        |> Unit.forKWh (Process.getImpact trigram countryElecProcess)
                )
    }


useImpacts :
    Impacts
    ->
        { useNbCycles : Int
        , ironingProcess : Process
        , nonIroningProcess : Process
        , countryElecProcess : Process
        }
    -> Mass
    -> { kwh : Energy, impacts : Impacts }
useImpacts impacts { useNbCycles, ironingProcess, nonIroningProcess, countryElecProcess } baseMass =
    let
        totalKWh =
            -- Note: Ironing is expressed per-item, non-ironing is mass-depdendent
            [ ironingProcess.elec
            , nonIroningProcess.elec
                |> Quantity.multiplyBy (Mass.inKilograms baseMass)
            ]
                |> Quantity.sum
                |> Quantity.multiplyBy (toFloat useNbCycles)
    in
    { kwh = totalKWh
    , impacts =
        impacts
            |> Impact.mapImpacts
                (\trigram _ ->
                    Quantity.sum
                        [ totalKWh
                            |> Unit.forKWh (Process.getImpact trigram countryElecProcess)
                        , Process.getImpact trigram ironingProcess
                            |> Quantity.multiplyBy (toFloat useNbCycles)
                        , baseMass
                            |> Unit.forKg (Process.getImpact trigram nonIroningProcess)
                            |> Quantity.multiplyBy (toFloat useNbCycles)
                        ]
                )
    }



-- Transports


transportRatio : Unit.Ratio -> Transport -> Transport
transportRatio airTransportRatio ({ road, sea, air } as transport) =
    let
        roadSeaRatio =
            Transport.roadSeaTransportRatio transport
    in
    { transport
        | road = road |> Quantity.multiplyBy (roadSeaRatio * (1 - Unit.ratioToFloat airTransportRatio))
        , sea = sea |> Quantity.multiplyBy ((1 - roadSeaRatio) * (1 - Unit.ratioToFloat airTransportRatio))
        , air = air |> Quantity.multiplyBy (Unit.ratioToFloat airTransportRatio)
    }
