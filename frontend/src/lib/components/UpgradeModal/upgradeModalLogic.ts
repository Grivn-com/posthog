import { actions, connect, kea, listeners, path, reducers, selectors } from 'kea'

import { eventUsageLogic } from 'lib/utils/eventUsageLogic'
import { billingLogic } from 'scenes/billing/billingLogic'
import { preflightLogic } from 'scenes/PreflightCheck/preflightLogic'
import { userLogic } from 'scenes/userLogic'

import { AvailableFeature } from '~/types'

import type { upgradeModalLogicType } from './upgradeModalLogicType'

export type GuardAvailableFeatureFn = (
    featureKey?: AvailableFeature,
    featureAvailableCallback?: () => void,
    options?: {
        guardOnCloud?: boolean
        guardOnSelfHosted?: boolean
        currentUsage?: number
        isGrandfathered?: boolean
    }
) => boolean

export const upgradeModalLogic = kea<upgradeModalLogicType>([
    path(['lib', 'components', 'UpgradeModal', 'upgradeModalLogic']),
    connect(() => ({
        values: [
            preflightLogic,
            ['preflight'],
            billingLogic,
            ['billing'],
            userLogic,
            ['hasAvailableFeature', 'availableFeature'],
        ],
    })),
    actions({
        showUpgradeModal: (featureKey: AvailableFeature, currentUsage?: number, isGrandfathered?: boolean) => ({
            featureKey,
            currentUsage,
            isGrandfathered,
        }),
        hideUpgradeModal: true,
    }),
    reducers({
        upgradeModalFeatureKey: [
            null as AvailableFeature | null,
            {
                showUpgradeModal: (_, { featureKey }) => featureKey,
                hideUpgradeModal: () => null,
            },
        ],
        upgradeModalFeatureUsage: [
            null as number | null,
            {
                showUpgradeModal: (_, { currentUsage }) => currentUsage ?? null,
                hideUpgradeModal: () => null,
            },
        ],
        upgradeModalIsGrandfathered: [
            null as boolean | null,
            {
                showUpgradeModal: (_, { isGrandfathered }) => isGrandfathered ?? null,
                hideUpgradeModal: () => null,
            },
        ],
    }),
    selectors(({ actions }) => ({
        projectLimit: [
            (s) => [s.availableFeature],
            (availableFeature) => availableFeature(AvailableFeature.ORGANIZATIONS_PROJECTS)?.limit ?? 6,
        ],
        shouldShowPlatformAddonMessage: [
            (s) => [s.upgradeModalFeatureKey, s.billing],
            (upgradeModalFeatureKey, billing) => {
                if (upgradeModalFeatureKey !== AvailableFeature.ORGANIZATIONS_PROJECTS) {
                    return false
                }

                const platformAndSupportProduct = billing?.products?.find(
                    (product) => product.type === 'platform_and_support'
                )
                const hasPlatformAddon = platformAndSupportProduct?.addons?.some((addon) => addon.subscribed) ?? false

                return billing?.subscription_level === 'paid' && !hasPlatformAddon
            },
        ],
        guardAvailableFeature: [
            (s) => [s.preflight, s.hasAvailableFeature],
            (): GuardAvailableFeatureFn => {
                // [CUSTOMIZATION] Always grant access — no upgrade modal
                return (_featureKey, featureAvailableCallback): boolean => {
                    featureAvailableCallback?.()
                    return true
                }
            },
        ],
    })),
    listeners(() => ({
        showUpgradeModal: ({ featureKey }) => {
            eventUsageLogic.actions.reportUpgradeModalShown(featureKey)
        },
    })),
])
