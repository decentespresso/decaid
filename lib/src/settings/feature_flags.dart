enum FeatureFlag { stepExitArbiter, largeBleMtuNonAndroid }

const Map<FeatureFlag, bool> defaultFeatureFlagValues = {
  FeatureFlag.stepExitArbiter: true,
  FeatureFlag.largeBleMtuNonAndroid: false,
};
