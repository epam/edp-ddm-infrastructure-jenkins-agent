package com.epam.edp.stages.impl.ci.impl.builddockerfileimage

import com.epam.edp.stages.impl.ci.ProjectType
import com.epam.edp.stages.impl.ci.Stage
import com.epam.edp.stages.impl.ci.impl.codebaseiamgestream.CodebaseImageStreams

@Stage(name = "build-image-from-dockerfile", buildTool = ["docker"], type = [ProjectType.APPLICATION])
class BuildDockerfileImageHelm {
    Script script

    def buildConfigApi = "buildconfig"

    void createOrUpdateBuildConfig(codebase, buildConfigName, imageUrl) {
        if (!script.openshift.selector(buildConfigApi, "${buildConfigName}").exists()) {
            script.openshift.newBuild(codebase.imageBuildArgs)
            return
        }
        script.sh("oc patch --type=merge ${buildConfigApi} ${buildConfigName} -p \"{\\\"spec\\\":{\\\"output\\\":{\\\"to\\\":{\\\"name\\\":\\\"${imageUrl}\\\"}}}}\" ")
    }

    void run(context) {
        if (!script.fileExists("${context.workDir}/Dockerfile")) {
            script.error "[JENKINS][ERROR] There is no Dockerfile in the root directory of the project ${context.codebase.name}. "
        }

        def resultTag
        script.openshift.withCluster() {
            script.openshift.withProject() {
                script.env.dockerRegistryHost = context.platform.getJsonPathValue("edpcomponent", "docker-registry", ".spec.url")
                if (!script.env.dockerRegistryHost) {
                    script.error("[JENKINS][ERROR] Couldn't get docker registry server")
                }
                script.env.dockerProxyRegistry = context.job.dnsWildcard.startsWith("apps.cicd") ? 'nexus-docker-registry.' + context.job.dnsWildcard + '/' : ''
                script.env.ciProject = (context.job.dnsWildcard ==~ /apps.cicd?.mdtu-ddm.projects.epam.com/) ? 'mdtu-ddm-edp-cicd' : context.job.edpName

                def dockerfileString = script.readFile file: "${context.workDir}/Dockerfile"
                dockerfileString = dockerfileString.replaceAll(/FROM (.*)/, "FROM ${script.env.dockerProxyRegistry}" + '\$1')
                script.writeFile(file: "${context.workDir}/Dockerfile", text: dockerfileString)

                def buildconfigName = "${context.codebase.name}-dockerfile-${context.git.branch.replaceAll("[^\\p{L}\\p{Nd}]+", "-")}"
                def outputImagestreamName = "${context.codebase.name}-${context.git.branch.replaceAll("[^\\p{L}\\p{Nd}]+", "-")}"
                def imageRepository = "${script.env.dockerRegistryHost}/${context.job.ciProject}/${outputImagestreamName}"

                context.codebase.imageBuildArgs.push("--name=${buildconfigName}")

                def imageUrl = "${imageRepository}:${context.codebase.isTag}"
                context.codebase.imageBuildArgs.push("--to=${imageUrl}")
                context.codebase.imageBuildArgs.push("--binary=true")
                context.codebase.imageBuildArgs.push("--to-docker=true")
                context.codebase.imageBuildArgs.push("--push-secret=nexus-docker-registry")

                createOrUpdateBuildConfig(context.codebase, buildconfigName, imageUrl)

                script.dir(context.codebase.deployableModuleDir) {
                    if ("${context.workDir}" != "${context.codebase.deployableModuleDir}") {
                        script.sh "cp ${context.workDir}/Dockerfile ${context.codebase.deployableModuleDir}/"
                    }

                    script.sh "tar -cf ${context.codebase.name}.tar *"

                    def buildResult = script.openshift.selector(buildConfigApi, "${buildconfigName}").startBuild(
                            "--from-archive=${context.codebase.name}.tar",
                            "--wait=true")
                    resultTag = buildResult.object().status.output.to.imageDigest
                }
                script.println("[JENKINS][DEBUG] Build config ${context.codebase.name} with result " +
                        "${buildconfigName}:${resultTag} has been completed")

                new CodebaseImageStreams(context, script)
                        .UpdateOrCreateCodebaseImageStream(outputImagestreamName, imageRepository, context.codebase.isTag)

            }
        }
    }
}

return BuildDockerfileImageHelm
