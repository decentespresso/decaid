enum FeatureFlag {
  stepExitArbiter,
  largeBleMtuNonAndroid,
  androidTextureLayerComposition,
}

const Map<FeatureFlag, bool> defaultFeatureFlagValues = {
  FeatureFlag.stepExitArbiter: true,
  FeatureFlag.largeBleMtuNonAndroid: false,
  FeatureFlag.androidTextureLayerComposition: false,
};
