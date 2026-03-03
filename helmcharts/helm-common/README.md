## Validate helm template

```
helm template <version>.tgz --namespace <namespace> -f values.yaml > template-file.yaml
```

## Package Helm:

```
helm package <directory>
```

## Example:

```
helm package helm
helm template helm-common-0.1.1.tgz --namespace <namespace> -f values.yaml > template-file.yaml
```

